require "digest"
require "securerandom"
require "set"

class Provider::AccountData::Syncer
  LEASE_DURATION = 10.minutes
  MONETARY_FIELDS = { balance: :current_balance, available_balance: :available_balance,
    cash_balance: :cash_balance, reserved_balance: :reserved_balance }.freeze

  def initialize(connection, adapter: nil, request_grant: nil)
    @connection = connection
    @adapter = adapter
    @request_grant = request_grant
  end

  def perform_sync(sync)
    @sync = sync
    @execution = sync.provider_execution
    @lease_acquired = false
    @inventory_balances = Set.new
    raise ArgumentError, "Sync belongs to another connection" unless sync.syncable == connection
    if @adapter.respond_to?(:request_grant) && @adapter.request_grant && @request_grant && !@adapter.request_grant.equal?(@request_grant)
      raise Provider::AccountData::StaleWriter, "A constructed adapter cannot replace its captured request grant"
    end
    claim_lease!
    @request_grant ||= @adapter.request_grant if @adapter.respond_to?(:request_grant)
    @request_grant ||= Provider::AccountData::RequestGrant.new(connection)
    @request_grant.assert_connection!(connection)
    @request_grant.bind_execution!(@execution) if @execution
    if @adapter
      # An explicitly injected adapter is a trusted execution/test dependency.
      # Production factories capture their actual credentials under this grant.
      @request_grant.capture!(scope_sync: sync)
    else
      @adapter = Provider::AccountData::Registry.build(connection, observed_at: sync.created_at, sync: sync, request_grant: @request_grant)
    end
    errors = []
    inventory_complete = false
    begin
      run_stream("accounts") { |cursor, _window| adapter.list_accounts(cursor: cursor) }
      inventory_complete = true
    rescue Provider::AccountData::DeferredPage
      # An asynchronous export must finish discovery before its account streams
      # can read the same snapshot. Its progress is already durable here.
      raise
    rescue Provider::AccountData::IncompletePage => error
      # Aggregators may return usable institutions alongside failed ones. Retain
      # the incomplete inventory, leave its checkpoint unchanged, and attempt
      # independent account streams before reporting the incomplete run.
      capture_failure(error)
      errors << error
    end
    fenced do
      connection.update!(pending_account_setup: connection.external_accounts.where(status: "active").left_joins(:account_provider).where(account_providers: { id: nil }).exists?)
    end

    if adapter.is_a?(Provider::AccountData::Wise)
      raise Provider::AccountData::IncompletePage, "Wise statements require complete profile inventory" unless inventory_complete
      @wise_statement_barrier = Provider::AccountData::Wise::StatementBarrier.new(connection: connection, sync: sync,
        adapter: adapter, writer_epoch: @writer_epoch, fence: method(:fenced), request_grant: @request_grant,
        record_builder: method(:record_for), window_builder: ->(external, checkpoint) { window_for(external, checkpoint, stream: "transactions") }).perform
    end

    connection_transactions_complete = true
    if connection_transaction_scope?
      begin
        Provider::AccountData::TransactionSync.new(connection: connection, sync: sync, adapter: adapter,
          writer_epoch: @writer_epoch, fence: method(:fenced), request_grant: @request_grant).perform
      rescue Provider::AccountData::DeferredPage => error
        connection_transactions_complete = false
        errors << error
      rescue Provider::AccountData::StaleWriter
        raise
      rescue StandardError => error
        connection_transactions_complete = false
        capture_failure(error)
        errors << error
      end
    end

    if connection_activity_scope?
      begin
        raise Provider::AccountData::IncompletePage, "Activity generation requires complete inventory" unless inventory_complete
        Provider::AccountData::TransactionSync.new(connection: connection, sync: sync, adapter: adapter, resource: "activities",
          writer_epoch: @writer_epoch, fence: method(:fenced), request_grant: @request_grant).perform
      rescue Provider::AccountData::DeferredPage
        # Later quote/balance reads can rotate the same cookie. Leave the
        # retained activity request lineage untouched until it resumes.
        raise
      rescue Provider::AccountData::StaleWriter
        raise
      rescue StandardError => error
        capture_failure(error)
        raise
      end
    end

    account_ids_in_sync_order.each do |external_id|
      external_account = connection.external_accounts.find(external_id)
      break if sync.cancel_requested?
      deferred_account = false
      failed_account = false
      streams = [ "balances", *adapter.capabilities ]
      streams.delete("transactions") if connection_transaction_scope?
      streams.delete("activities") if connection_activity_scope?
      streams, dependencies = account_stream_order(streams)
      completed_streams = Set.new
      streams.each do |stream|
        # Its prerequisite already retained the precise failure/continuation.
        # A skipped dependent resource must not turn a deferral into a hard error.
        next unless dependencies.fetch(stream, []).all? { |prerequisite| completed_streams.include?(prerequisite) }
        method = { "balances" => :fetch_balance, "transactions" => :fetch_transactions,
                   "holdings" => :fetch_holdings, "activities" => :fetch_activities }.fetch(stream)
        run_stream(stream, external_account: external_account) do |cursor, window, account_record|
          adapter.public_send(method, account: account_record, cursor: cursor, window: window)
        end
        completed_streams.add(stream)
      rescue Provider::AccountData::DeferredPage => error
        deferred_account = true
        errors << error
      rescue Provider::AccountData::StaleWriter
        raise
      rescue StandardError => error
        failed_account = true
        # An independent balance or holdings response remains usable when a
        # transaction endpoint is temporarily unavailable (and vice versa).
        capture_failure(error, external_account: external_account)
        errors << error
      end
      next if deferred_account
      if connection.provider_key == "ibkr"
        # Historical equity must describe the same completed export as every
        # account stream. Partial streams may persist evidence, but cannot
        # schedule a calculation from a mixture of old and new financial inputs.
        next if failed_account || !inventory_complete || !connection_transactions_complete || sync.cancel_requested?
        Provider::AccountData::Ibkr::AccountHandoff.new(connection: connection, sync: sync,
          external_account: external_account, writer_epoch: @writer_epoch, fence: method(:fenced)).enqueue!
        next
      end
      # Recheck the worker before taking the parent lock. Cancellation and child
      # creation then share that lock, closing the descendant-scan race.
      fenced do
        sync.with_lock do
          unless sync.cancel_requested_at? || sync.terminal?
            external_account.current_account.sync_later(
              parent_sync: sync, window_start_date: sync.window_start_date, window_end_date: sync.window_end_date
            )
          end
        end
      end
    rescue Provider::AccountData::StaleWriter
      raise
    rescue StandardError => error
      capture_failure(error, external_account: external_account)
      errors << error
    end
    # Finish the original page sequence before examining an older counterpart.
    # Pair review must not replace a durable account continuation with an
    # unrelated historical-evidence failure.
    if adapter.is_a?(Provider::AccountData::Wise) && errors.none? { |error| error.is_a?(Provider::AccountData::DeferredPage) }
      Provider::AccountData::Wise::InterbalanceTransfers.new(connection: connection, sync: sync,
        adapter: adapter, barrier: @wise_statement_barrier).perform
    end
    if errors.any? && errors.all? { |error| error.is_a?(Provider::AccountData::DeferredPage) }
      raise errors.min_by(&:resume_at)
    end
    raise errors.first if errors.one? && errors.first.is_a?(Provider::AccountData::IncompletePage)
    raise Provider::AccountData::Error, "One or more account streams failed" if errors.any?
  rescue Provider::AccountData::DeferredPage
    raise
  rescue StandardError => error
    capture_failure(error)
    raise if error.is_a?(Provider::AccountData::Error)
    raise Provider::AccountData::Error.new("Shared account ingestion failed"), cause: nil
  ensure
    release_lease! if @lease_acquired
  end

  def perform_post_sync
    # Account child syncs materialize balances; Family post-sync owns transfers
    # and the existing transaction rules.
  end

  private
    attr_reader :connection, :adapter, :sync

    def connection_transaction_scope?
      adapter.respond_to?(:transaction_scope) && adapter.transaction_scope == :connection
    end

    def connection_activity_scope?
      adapter.respond_to?(:activity_scope) && adapter.activity_scope == :connection
    end

    def claim_lease!
      if @execution
        @execution.fenced do
          unless @execution.connection.id == connection.id && @execution.sync.id == sync.id
            raise Provider::AccountData::StaleWriter, "Provider execution belongs to another sync"
          end
          @lease_owner = @execution.lease_owner
          @writer_epoch = @execution.writer_epoch
        end
        return
      end

      # Direct callers are retained for isolated adapter execution. SyncJob owns
      # the production lease for the whole dispatch/finalization lifecycle.
      connection.with_lock do
        sync.lock!
        unless connection.status == "good" && !connection.scheduled_for_deletion
          raise Provider::AccountData::StaleWriter, "Connection is not eligible to sync"
        end
        control = connection.provider_migration_control
        if control && !control.native_owned?
          raise Provider::AccountData::StaleWriter, "Legacy provider still owns this connection"
        end
        if connection.lease_expires_at && connection.lease_expires_at > Time.current
          # A cancelled predecessor can remain inside its final fenced operation.
          # The eligible successor keeps the same durable execution until that
          # lease expires, without building credentials or making another read.
          raise Provider::AccountData::DeferredPage.new(resume_at: [ connection.lease_expires_at, 15.seconds.from_now ].min)
        end
        if !sync.in_progress? || sync.send(:continuation_cancelled?) ||
            (connection.lease_sync_id && connection.lease_sync_id != sync.id &&
              Sync.incomplete.where(id: connection.lease_sync_id).exists?)
          raise Provider::AccountData::StaleWriter, "Provider execution cannot claim this sync"
        end
        @lease_owner = SecureRandom.uuid
        @writer_epoch = connection.writer_epoch + 1
        @execution_revision = sync.provider_execution_revision
        connection.update!(writer_epoch: @writer_epoch, lease_sync_id: sync.id,
          lease_owner: @lease_owner, lease_expires_at: LEASE_DURATION.from_now)
      end
      @lease_acquired = true
    end

    def assert_lease!
      return @execution.assert_current!(connection: connection) if @execution

      control = ProviderMigrationControl.find_by(provider_connection_id: connection.id)
      unless connection.lease_owner == @lease_owner && connection.writer_epoch == @writer_epoch &&
          connection.lease_sync_id == sync.id && sync.provider_execution_revision == @execution_revision &&
          sync.in_progress? && !sync.send(:continuation_cancelled?) &&
          connection.lease_expires_at && connection.lease_expires_at > Time.current &&
          connection.status == "good" && !connection.scheduled_for_deletion &&
          (control.nil? || control.native_owned?)
        raise Provider::AccountData::StaleWriter, "Ingestion writer lost its lease"
      end
    end

    def fenced
      return @execution.fenced { yield } if @execution

      connection.with_lock do
        sync.lock!
        assert_lease!
        result = yield
        connection.update!(lease_expires_at: LEASE_DURATION.from_now)
        result
      end
    end

    def release_lease!
      stored = ProviderConnection.find(connection.id)
      stored.with_lock do
        sync.lock!
        if stored.lease_owner == @lease_owner && stored.writer_epoch == @writer_epoch &&
            stored.lease_sync_id == sync.id && sync.provider_execution_revision == @execution_revision
          stored.update!(lease_owner: nil, lease_expires_at: nil, lease_sync_id: nil)
        end
      end
    end

    def run_stream(stream, external_account: nil)
      scope_key = external_account ? "account:#{external_account.id}" : "connection"
      checkpoint = connection.provider_sync_checkpoints.find_by(stream: stream, scope_key: scope_key)
      original_epoch = connection.ingestion_batches.where(sync: sync, stream: stream, scope_key: scope_key).minimum(:writer_epoch) || @writer_epoch
      fenced { reject_newer_stream!(stream, scope_key, original_epoch) }
      # A delayed attempt continues one logical sync. Completed independent
      # streams keep their captured result instead of fetching another snapshot.
      if checkpoint&.ingestion_batch&.sync_id == sync.id &&
          checkpoint.state["progress"].nil? && checkpoint.ingestion_batch.complete? && checkpoint.ingestion_batch.applied?
        if stream == "accounts"
          connection.ingestion_batches.where(sync: sync, stream: "accounts", status: "applied").find_each do |captured|
            remember_inventory(Ingestion::Codec.load(captured.payload))
          end
        end
        return
      end
      progress = resumable_progress(checkpoint, stream: stream, external_account: external_account)
      allow_absence = progress.nil?
      cursor = progress&.fetch("cursor") || checkpoint&.cursor
      window = window_for(external_account, checkpoint, stream: stream)
      request_inputs = Provider::AccountData::RequestInputs.new(connection: connection, sync: sync, stream: stream,
        external_account: external_account, record_builder: ->(current) { request_record_for(current, stream: stream) },
        history_metadata_keys: history_metadata_keys(stream))
      window_configuration = request_inputs.configuration
      checkpoint_revision = request_inputs.checkpoint_fingerprint(checkpoint)
      sequence = 0
      seen_cursors = Set.new
      observed_pending_ids = []
      loop do
        raise Provider::AccountData::IncompletePage, "Sync was cancelled" if sync.cancel_requested?
        key_parts = [ sync.id, stream, scope_key, sequence ]
        key_parts += [ "attempt", sync.provider_attempt ] if sync.provider_attempt.positive?
        key = Digest::SHA256.hexdigest(key_parts.join(":"))
        batch = connection.ingestion_batches.find_by(idempotency_key: key)
        unless batch
          # The full factory account union is locked before this one-account
          # binding/Record. HTTP receives exactly the immutable admitted inputs.
          admission = nil
          response, grant_capture = @request_grant.capture_request(scope_sync: sync, admit: lambda {
            assert_lease!
            admission = request_inputs.capture!(request_key: key, configuration: window_configuration,
              checkpoint: checkpoint_revision, window: window, cursor: cursor)
          }) do |inputs|
            yield inputs.fetch(:cursor), inputs.fetch(:window), inputs.fetch(:record)
          end
          binding = admission.fetch(:binding)
          page = Provider::AccountData::RequestGrant.attach(response, grant_capture)
          page = Provider::AccountData::RequestInputs.attach(page, admission.fetch(:evidence))
          validate_page!(page, stream: stream, external_account: external_account)
          batch = fenced do
            connection.ingestion_batches.create!(
              family: connection.family, sync: sync, external_account: external_account,
              origin_kind: "provider", stream: stream, scope_key: scope_key,
              sequence: sequence, idempotency_key: key, mode: page.mode,
              complete: page.complete?, coverage: page.coverage.as_json,
              payload: Ingestion::Codec.dump(page), ruleset_snapshot: {},
              source_policy_version: binding["source_policy_version"], source_binding: binding, writer_epoch: @writer_epoch
            )
          end
        end
        page = Ingestion::Codec.load(batch.payload)
        validate_page!(page, stream: stream, external_account: external_account)
        remember_inventory(page) if stream == "accounts"
        if sequence.zero?
          window = window.merge(page.coverage.slice("start", "end"))
        end
        observed_pending_ids.concat(page.records.filter_map { |record| record[:external_id] if record.kind == "transaction" && record[:pending] })
        securities = prepare_securities(page, batch, external_account)
        inventory_transition = nil
        fenced do
          batch.reload
          if batch.status == "applied"
            observed_pending_ids.concat(SourceRecord.where(ingestion_batch: batch, pending: true).pluck(:external_id))
          end
          unless batch.status == "applied"
            reject_newer_stream!(stream, scope_key, original_epoch)
            Provider::AccountData::RequestGrant.verify_capture!(connection: connection,
              capture: page.evidence[Provider::AccountData::RequestGrant::EVIDENCE_KEY], require_runtime_inputs: @request_grant.runtime_inputs?, scope_sync: sync)
            request_inputs.verify!(batch: batch, evidence: page.evidence[Provider::AccountData::RequestInputs::EVIDENCE_KEY])
            if stream == "accounts"
              if connection.provider_key == "enable_banking"
                inventory_transition = Provider::AccountData::EnableBanking::AuthorizationInventory.new(connection: connection, sync: sync, execution: @execution)
                  .publish!(page: page, batch: batch, adapter: adapter, request_grant: @request_grant, request_cursor: cursor) { |record| store_external_account(record) }
              else
                page.records.each { |record| store_external_account(record) }
              end
            else
              store_external_account(page.records.first, external_account: external_account) if stream == "balances" && page.records.any?
              Ingestion::LedgerWriter.new(external_account: external_account, batch: batch, securities: securities)
                .apply(page, observed_pending_ids: observed_pending_ids, allow_absence: allow_absence)
            end
            batch.update!(status: "applied", applied_at: Time.current, error_code: nil)
            if connection.provider_key == "wise" && stream == "transactions"
              Provider::AccountData::Wise::StatementHistory.record_applied!(external_account: external_account, batch: batch, page: page)
            end
            if page.complete? || page.progress_cursor
              checkpoint = connection.provider_sync_checkpoints.find_or_initialize_by(stream: stream, scope_key: scope_key)
              checkpoint.assign_attributes(family: connection.family, external_account: external_account)
              if page.complete?
                checkpoint.assign_attributes(
                  ingestion_batch: batch, cursor: page.checkpoint_cursor,
                  state: { "coverage" => page.coverage.as_json }, covered_through: covered_through(page, checkpoint)
                )
              else
                # Persist fetched history without claiming that its entire
                # requested scope is complete or advancing the coverage boundary.
                checkpoint.state = checkpoint.state.merge("progress" => { "cursor" => page.progress_cursor, "ingestion_batch_id" => batch.id })
              end
              checkpoint.save!
            end
          end
        end
        if inventory_transition
          @adapter, @request_grant = inventory_transition.adapter, inventory_transition.request_grant
        end
        checkpoint_revision = request_inputs.checkpoint_fingerprint(checkpoint)
        break if page.complete?
        if page.coverage["available_at"]
          raise Provider::AccountData::DeferredPage.new(resume_at: Time.iso8601(page.coverage.fetch("available_at")))
        end
        unless page.next_cursor && seen_cursors.add?(page.next_cursor)
          raise Provider::AccountData::IncompletePage, "Incomplete or repeating page chain"
        end
        cursor = page.next_cursor
        sequence += 1
      end
    end

    def resumable_progress(checkpoint, stream:, external_account:)
      scope = adapter.respond_to?(:progress_cursor_scope) ? adapter.progress_cursor_scope(stream: stream) : :connection
      unless %i[connection sync].include?(scope)
        raise Provider::AccountData::InvalidResponse, "Invalid fetch progress scope"
      end
      progress = checkpoint&.state&.dig("progress")
      return progress if progress.nil? || scope == :connection

      batch = connection.ingestion_batches.find_by(id: progress["ingestion_batch_id"])
      unless batch&.applied? && batch.family_id == connection.family_id && batch.stream == stream &&
          batch.scope_key == checkpoint.scope_key && batch.external_account_id == external_account&.id &&
          batch.provider_authorization_id.nil?
        raise Provider::AccountData::StaleWriter, "Fetch progress has no applied batch for this scope"
      end
      # Preserve the old batch and actual checkpoint fingerprint. The first new
      # response replaces progress only after the ordinary grant and checkpoint
      # checks succeed; failure before publication leaves all prior evidence.
      progress if batch.sync_id == sync.id
    end

    def validate_page!(page, stream:, external_account: nil)
      unless page.is_a?(Provider::AccountData::Page)
        raise Provider::AccountData::InvalidResponse, "Adapter must return a canonical page"
      end
      kind = { "accounts" => "account", "balances" => "account", "transactions" => "transaction",
               "holdings" => "holding", "activities" => "activity" }.fetch(stream)
      unless page.records.all? { |record| record.kind == kind }
        raise Provider::AccountData::InvalidResponse, "Unexpected record kind"
      end
      if stream == "balances" && !(page.records.empty? && !page.complete?) &&
          (!page.records.one? || page.records.first[:external_id] != external_account.external_id)
        raise Provider::AccountData::InvalidResponse, "Balance response belongs to another account"
      end
      if page.removed_ids.any? && (stream != "transactions" || !page.complete? || page.coverage.with_indifferent_access[:removal_policy] != "exact_external_id")
        raise Provider::AccountData::UnsupportedCapability, "Explicit source removals require a completed transaction change set"
      end
      if page.coverage.key?("available_at")
        begin
          available_at = Time.iso8601(page.coverage.fetch("available_at"))
          unless !page.complete? && page.next_cursor.nil? && page.progress_cursor && available_at < sync.created_at + Sync::STALE_AFTER
            raise ArgumentError
          end
        rescue ArgumentError, TypeError
          raise Provider::AccountData::InvalidResponse, "Deferred data requires bounded durable fetch progress"
        end
      end
    end

    def remember_inventory(page)
      page.records.each do |record|
        @inventory_balances << [ "connection", record[:external_id] ] if !record[:balance].nil? || !record[:available_balance].nil?
      end
    end

    def reject_newer_stream!(stream, scope_key, original_epoch)
      newer = connection.ingestion_batches.where(stream: stream, scope_key: scope_key, status: "applied")
        .where.not(sync_id: sync.id).where("writer_epoch > ?", original_epoch)
      raise Provider::AccountData::StaleWriter, "A newer sync has already applied this resource" if newer.exists?
    end

    def prepare_securities(page, batch, external_account)
      return {} if batch.applied? || external_account.nil? || page.records.none? { |record| record[:security] }
      policy = Account::SourcePolicy.active.find_by(account: external_account.current_account, resource: batch.stream)
      return {} unless policy&.id == batch.source_policy_version && policy.account_provider_id == external_account.account_provider.id
      Ingestion::SecurityResolver.new(account: external_account.current_account).resolve(page)
    end

    def account_ids_in_sync_order
      # Budgeted integrations must not starve accounts later in UUID order.
      # A completed transaction checkpoint is the fair scheduling boundary;
      # partially fetched history does not pretend that an account is up to date.
      connection.external_accounts.where(status: "active").joins(:account).merge(Account.visible)
        .joins("LEFT JOIN provider_sync_checkpoints AS transaction_checkpoints ON transaction_checkpoints.external_account_id = external_accounts.id AND transaction_checkpoints.stream = 'transactions' AND transaction_checkpoints.scope_key = 'account:' || external_accounts.id::text")
        .order(Arel.sql("transaction_checkpoints.covered_through ASC NULLS FIRST, external_accounts.id ASC"))
        .pluck("external_accounts.id")
    end

    def store_external_account(record, external_account: nil)
      external = if external_account
        connection.external_accounts.where(family_id: connection.family_id).find(external_account.id).tap do |selected|
          unless selected.external_id == record[:external_id] && selected.identity_namespace == external_account.identity_namespace
            raise Provider::AccountData::InvalidResponse, "Balance metadata belongs to another source account"
          end
        end
      else
        connection.external_accounts.find_or_initialize_by(identity_namespace: "connection", external_id: record[:external_id])
      end
      metadata = (record[:metadata] || {}).deep_stringify_keys.except("linked_account_type", "balance_snapshot_current",
        "runtime_external_account_id", "runtime_identity_namespace")
      metadata["reported_currency"] = record[:currency] if record[:currency]
      external.assign_attributes(
        family: connection.family, provider_key: connection.provider_key,
        name: record[:name], metadata: external.metadata.deep_merge(metadata),
        sensitive_details: external.sensitive_details.deep_merge((record[:sensitive_details] || {}).deep_stringify_keys)
      )
      valued = metadata["balance_provided"] != false && MONETARY_FIELDS.keys.any? { |key| !record[key].nil? }
      currency_changed = external.currency.present? && record[:currency] && external.currency != record[:currency]
      if currency_changed && valued
        # A new unit cannot inherit omitted monetary fields from the old unit.
        MONETARY_FIELDS.each_value { |column| external.public_send("#{column}=", nil) }
        external.balance_date = nil
      end
      external.currency = record[:currency] if record[:currency] && (!currency_changed || valued)
      external.account_type = record[:account_type] if record.attributes.key?(:account_type)
      # Discovery APIs can omit balance fields entirely. Omission is different
      # from an explicit nil (unavailable) or zero in a balance snapshot.
      unless metadata["balance_provided"] == false
        MONETARY_FIELDS.merge(balance_date: :balance_date).each do |input, target|
          external.public_send("#{target}=", record[input]) if record.attributes.key?(input)
        end
      end
      external.save!
      external
    end

    def record_for(external_account)
      reported_currency = external_account.metadata["reported_currency"] || external_account.currency || external_account.current_account&.currency
      unit_changed = external_account.currency.present? && reported_currency != external_account.currency
      Ingestion::Record.account(
        external_id: external_account.external_id, name: external_account.name,
        currency: reported_currency,
        account_type: external_account.account_type, balance: unit_changed ? nil : external_account.current_balance,
        available_balance: unit_changed ? nil : external_account.available_balance, cash_balance: unit_changed ? nil : external_account.cash_balance,
        reserved_balance: unit_changed ? nil : external_account.reserved_balance, balance_date: unit_changed ? nil : external_account.balance_date,
        metadata: external_account.metadata.merge("linked_account_type" => external_account.current_account&.accountable_type,
          "runtime_external_account_id" => external_account.id, "runtime_identity_namespace" => external_account.identity_namespace,
          "balance_snapshot_current" => !unit_changed && @inventory_balances.include?([ external_account.identity_namespace, external_account.external_id ])),
        sensitive_details: external_account.sensitive_details
      )
    end

    def request_record_for(external_account, stream:)
      record = record_for(external_account)
      return record unless stream == "balances" && adapter.is_a?(Provider::AccountData::Simplefin)

      input = Provider::AccountData::Simplefin::BalanceInput.new(connection: connection, sync: sync, external_account: external_account).capture
      Ingestion::Record.account(**record.attributes.merge(metadata: record[:metadata].merge("simplefin_balance_input" => input)))
    end

    def account_stream_order(streams)
      dependencies = adapter.respond_to?(:account_stream_dependencies) ? adapter.account_stream_dependencies : {}
      unless dependencies.is_a?(Hash) && (dependencies.keys - streams).empty? && dependencies.values.all? { |values|
          values.is_a?(Array) && values.uniq == values && (values - streams).empty?
        }
        raise Provider::AccountData::InvalidResponse, "Invalid account resource dependencies"
      end
      ordered = []
      until ordered.size == streams.size
        next_stream = streams.find { |stream| !ordered.include?(stream) && (dependencies.fetch(stream, []) - ordered).empty? }
        raise Provider::AccountData::InvalidResponse, "Cyclic account resource dependencies" unless next_stream
        ordered << next_stream
      end
      [ ordered, dependencies ]
    end

    def window_for(external_account, checkpoint, stream:)
      return @wise_statement_barrier.window_for(external_account.id) if stream == "transactions" && @wise_statement_barrier

      start = external_account&.sync_start_date || connection.sync_start_date ||
        (checkpoint&.covered_through ? checkpoint_history_start(external_account, stream, checkpoint) : initial_history_start(external_account, stream))
      if stream == "transactions" && adapter.is_a?(Provider::AccountData::Wise) && checkpoint&.covered_through.nil? &&
          checkpoint&.state&.dig("coverage", "history_complete") == false &&
          [ external_account&.sync_start_date, connection.sync_start_date, sync.window_start_date ].all?(&:nil?)
        # A completed transfer fallback did not prove statement history. Keep
        # retrying its original initial boundary instead of rolling it forward.
        start = Time.iso8601(checkpoint.state.fetch("coverage").fetch("start"))
      end
      start = sync.window_start_date if sync.window_start_date && (start.nil? || sync.window_start_date < start.to_date)
      if checkpoint&.covered_through.nil? && stream == "transactions" && adapter.is_a?(Provider::AccountData::Adapter)
        floor = adapter.initial_history_floor(account: history_account(external_account, stream), observed_at: sync.created_at)
        start = floor if floor && (start.nil? || utc_time(start) < utc_time(floor))
      end
      finish = sync.window_end_date ? sync.window_end_date.to_time(:utc).end_of_day : sync.created_at
      finish = [ finish, sync.created_at ].min
      { "start" => start && utc_time(start).iso8601, "end" => utc_time(finish).iso8601,
        "explicit_start" => (external_account&.sync_start_date || connection.sync_start_date || sync.window_start_date).present?,
        "checkpoint_covered_through" => checkpoint&.covered_through&.iso8601,
        "initial" => checkpoint&.covered_through.nil? }
    end

    def initial_history_start(external_account, stream)
      return sync.created_at - 90.days unless stream == "transactions" && adapter.is_a?(Provider::AccountData::Adapter)

      adapter.initial_history_start(account: history_account(external_account, stream), observed_at: sync.created_at)
    end

    def checkpoint_history_start(external_account, stream, checkpoint)
      return checkpoint.covered_through - 7.days unless stream == "transactions" && adapter.is_a?(Provider::AccountData::Adapter)

      adapter.checkpoint_history_start(account: history_account(external_account, stream),
        observed_at: sync.created_at, covered_through: checkpoint.covered_through)
    end

    def history_account(external_account, stream)
      Provider::AccountData::MigrationManifest.copy_value(metadata: external_account.metadata.slice(*history_metadata_keys(stream)))
    end

    def history_metadata_keys(stream)
      stream == "transactions" && adapter.is_a?(Provider::AccountData::Adapter) ? adapter.class.initial_history_metadata_keys : []
    end

    def utc_time(value)
      value.instance_of?(Date) ? value.to_time(:utc) : value.to_time.utc
    end

    def covered_through(page, checkpoint)
      return checkpoint.covered_through if page.coverage["supported"] == false || page.coverage["history_complete"] == false
      boundary = page.coverage["end"] ? Time.iso8601(page.coverage["end"]) : sync.created_at
      [ checkpoint.covered_through, boundary ].compact.max
    end

    def capture_failure(error, external_account: nil)
      DebugLogEntry.capture(
        category: "provider_sync_error", level: "error", message: "Shared account ingestion failed",
        source: self.class.name, provider_key: connection.provider_key, family: connection.family,
        account_provider: external_account&.account_provider,
        metadata: { provider_connection_id: connection.id, external_account_id: external_account&.id,
                    sync_id: sync&.id, error_class: error.class.name }
      )
    end
end
