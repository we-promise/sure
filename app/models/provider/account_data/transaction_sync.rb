require "digest"
require "json"
require "set"

# The fence is the Syncer's connection lease transaction. HTTP and complete-set
# compilation run outside it; child ledger writes and cursor promotion run inside.
class Provider::AccountData::TransactionSync
  MAX_RESTARTS = 2
  CHILD_SIZE = 1_000
  MAX_STORED_BYTES = 96 * 1024 * 1024
  MAX_DECODED_BYTES = 64 * 1024 * 1024
  MAX_TRANSPORT_RETRIES = 16
  MAX_RETRY_DELAY = 300

  def initialize(connection:, sync:, adapter:, writer_epoch:, fence:, ledger_writer: Ingestion::LedgerWriter, request_grant: nil, resource: "transactions")
    raise ArgumentError, "Unsupported connection resource" unless %w[transactions activities].include?(resource)
    @resource = resource
    @connection, @sync, @adapter, @writer_epoch, @fence = connection, sync, adapter, writer_epoch, fence
    if adapter.respond_to?(:request_grant) && adapter.request_grant && request_grant && !adapter.request_grant.equal?(request_grant)
      raise Provider::AccountData::StaleWriter, "A constructed adapter cannot replace its captured request grant"
    end
    @accounts = Provider::AccountData::GenerationAccounts.new(connection, resource: resource)
    @ledger_writer = ledger_writer
    @request_grant = request_grant || (adapter.request_grant if adapter.respond_to?(:request_grant)) || Provider::AccountData::RequestGrant.new(connection).capture!
    @request_grant.assert_connection!(connection)
    @request_grant.capture!(scope_sync: sync)
  end

  def perform
    unless sync.syncable == connection
      raise Provider::AccountData::StaleWriter, "Transaction sync belongs to another connection"
    end
    generation = prepare_generation
    return generation if generation.applied?
    restarts = 0
    begin
      fetch_generation(generation) if generation.fetching? && !terminal_captured?(generation)
    rescue Provider::AccountData::PaginationRestartRequired => error
      unless error.generation_id == generation.id && error.start_cursor == generation.start_cursor
        abandon(generation, "restart_scope_mismatch")
        raise Provider::AccountData::InvalidResponse, "Pagination restart changed its original scope"
      end
      abandon(generation, "pagination_restart")
      raise if restarts >= MAX_RESTARTS
      restarts += 1
      generation = fenced { create_generation }
      retry
    rescue Provider::AccountData::StaleWriter
      raise
    rescue StandardError
      abandon(generation, "fetch_failed") if generation.fetching? && !resumable?
      raise
    end
    seal(generation) if generation.fetching?
    apply_children(generation)
    promote(generation)
    generation
  end

  private
    attr_reader :connection, :sync, :adapter, :writer_epoch, :accounts, :resource

    def resumable?
      resource == "activities" && adapter.respond_to?(:resumable_activity_groups?) && adapter.resumable_activity_groups?
    end

    def group_stream
      resource == "activities" ? "activity_groups" : "transaction_groups"
    end

    def fenced(&block)
      @fence.call(&block)
    end

    def checkpoint
      connection.provider_sync_checkpoints.find_by(stream: resource, scope_key: "connection")
    end

    def prepare_generation
      fenced do
        previous = connection.provider_sync_generations.find_by(sync: sync, stream: resource, status: "applied")
        next previous if previous
        unfinished = connection.provider_sync_generations.unfinished.find_by(stream: resource, scope_key: "connection")
        if unfinished
          if resumable? && unfinished.sync_id != sync.id
            raise Provider::AccountData::StaleWriter, "Activity continuation belongs to its original sync"
          end
          if unfinished.sync.created_at > sync.created_at
            raise Provider::AccountData::StaleWriter, "A newer sync owns the unfinished transaction generation"
          end
          assert_checkpoint!(unfinished)
          # A crash after the terminal capture needs no more provider reads.
          # Transaction feeds restart an unfinished prefix at the committed
          # cursor. Reviewed activity adapters can resume their captured state.
          next unfinished if unfinished.sealed? || terminal_captured?(unfinished) || resumable?
          unfinished.update!(status: "abandoned", error_code: "interrupted_fetch")
        end
        create_generation
      end
    end

    def create_generation
      @request_grant.verify!
      current = checkpoint
      if current&.state&.key?("progress") || current&.external_account_id || current&.provider_authorization_id
        raise Provider::AccountData::InvalidResponse, "Connection cursor cannot reuse account fetch progress"
      end
      context = { "version" => 1, "accounts" => accounts.capture,
        "connection_grant" => connection_grant, "request_grant" => @request_grant.snapshot,
        "checkpoint" => { "id" => current&.id, "lock_version" => current&.lock_version } }
      connection.provider_sync_generations.create!(sync: sync, stream: resource, writer_epoch: writer_epoch, start_cursor: current&.cursor,
        context_snapshot: context, account_ids: Provider::AccountData::GenerationAccountIndex.capture_ids(context_snapshot: context, stream: resource))
    end

    def fetch_generation(generation)
      groups = resumable? ? load_groups(generation) : []
      cursor = groups.last&.next_cursor || generation.start_cursor
      seen = Set.new(groups.map(&:request_cursor))
      changes = groups.sum { |group| group.unassigned_removed_ids.size + group.account_pages.values.sum { |page| page.records.size + page.removed_ids.size } }
      fetched = 0
      (groups.size...Ingestion::TransactionGroupAssembler::MAX_PAGES).each do |sequence|
        raise Provider::AccountData::IncompletePage, "Sync was cancelled" if sync.cancel_requested?
        if resumable? && adapter.respond_to?(:activity_group_request_budget) && fetched >= adapter.activity_group_request_budget
          raise Provider::AccountData::DeferredPage.new(resume_at: 15.seconds.from_now)
        end
        receipt_scope = if resumable?
          ProviderCredentialReceipt.scope_for(generation: generation, page_sequence: sequence,
            writer_epoch: writer_epoch, lease_owner: connection.lease_owner)
        end
        begin
          response, grant_capture = @request_grant.capture_request(scope_sync: sync, receipt_scope: receipt_scope) do
            if resource == "activities"
              adapter.fetch_activity_group(start_cursor: generation.start_cursor, generation_id: generation.id, cursor: cursor,
                captured_groups: groups, accounts: generation.context_snapshot.fetch("accounts"))
            else
              adapter.fetch_transaction_group(start_cursor: generation.start_cursor, generation_id: generation.id, cursor: cursor)
            end
          end
        rescue StandardError => error
          defer_activity_transport!(generation, receipt_scope, error)
          raise
        end
        group = Provider::AccountData::RequestGrant.attach(response, grant_capture)
        unless group.is_a?(Provider::AccountData::TransactionGroup) && group.resource == resource && group.generation_id == generation.id &&
            group.start_cursor == generation.start_cursor && group.request_cursor == cursor && seen.add?(cursor) &&
            (group.complete? || !seen.include?(group.next_cursor))
          raise Provider::AccountData::InvalidResponse, "Transaction group changed pagination scope"
        end
        changes += group.unassigned_removed_ids.size + group.account_pages.values.sum { |page| page.records.size + page.removed_ids.size }
        raise Provider::AccountData::IncompletePage, "Transaction generation exceeds its change limit" if changes > Ingestion::TransactionGroupAssembler::MAX_CHANGES
        payload = Ingestion::TransactionGroupCodec.dump(group)
        decoded_bytes = groups.sum { |captured| JSON.generate(Ingestion::TransactionGroupCodec.dump(captured)).bytesize } + JSON.generate(payload).bytesize
        if decoded_bytes > MAX_DECODED_BYTES
          raise Provider::AccountData::IncompletePage, "Connection generation exceeds its decoded byte bound"
        end
        fenced do
          assert_checkpoint!(generation, pending_capture: grant_capture)
          generation.ingestion_batches.create!(**batch_context(generation), generation_role: "page", stream: group_stream,
            scope_key: "connection", sequence: sequence, idempotency_key: batch_key(generation, "page", sequence),
            mode: "delta", complete: group.complete?, payload: payload)
          generation.update!(page_count: sequence + 1)
        end
        groups << group
        fetched += 1
        return if group.complete?
        cursor = group.next_cursor
      end
      raise Provider::AccountData::IncompletePage, "Transaction generation exceeds its page limit"
    end

    def defer_activity_transport!(generation, receipt_scope, error)
      return unless receipt_scope && resumable? && adapter.respond_to?(:activity_group_retry_delay)
      return unless adapter.activity_group_retry_delay(error: error, attempt: generation.transport_retry_count)

      resume_at = fenced do
        generation.reload
        # Revalidate confirmed cookie receipts before scheduling; a transient
        # transport exception cannot hide revoked ownership or a changed prefix.
        assert_checkpoint!(generation)
        ProviderCredentialReceipt.verify_live_scope!(connection: connection, scope: receipt_scope)
        count = generation.transport_retry_count
        delay = adapter.activity_group_retry_delay(error: error, attempt: count)
        next unless delay
        unless count < MAX_TRANSPORT_RETRIES && delay.is_a?(Integer) && delay.between?(1, MAX_RETRY_DELAY)
          raise Provider::AccountData::InvalidResponse, "Activity retry policy exceeds its boundary"
        end
        generation.update!(transport_retry_count: count + 1)
        delay.seconds.from_now
      end
      raise Provider::AccountData::DeferredPage.new(resume_at: resume_at) if resume_at
    end

    def terminal_captured?(generation)
      return load_groups(generation).last&.complete? if resumable?
      last = generation.pages.reorder(sequence: :desc).first
      last && Ingestion::TransactionGroupCodec.load(last.payload).complete?
    end

    def seal(generation)
      groups = load_groups(generation)
      assembled = Ingestion::TransactionGroupAssembler.new(removal_accounts: removal_accounts(groups)).assemble(groups)
      bindings = generation.context_snapshot.fetch("accounts")
      unless (assembled.keys - bindings.keys).empty?
        raise Provider::AccountData::InvalidResponse, "Transaction changes include an account absent from the captured inventory"
      end
      fenced do
        generation.reload
        assert_checkpoint!(generation)
        groups.each do |group|
          next if resumable? # assert_checkpoint! verifies the complete rotation chain.
          capture = group.evidence[Provider::AccountData::RequestGrant::EVIDENCE_KEY]
          Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: capture,
            require_runtime_inputs: @request_grant.runtime_inputs?, scope_sync: sync)
          unless capture.fetch("after") == generation.context_snapshot.fetch("request_grant")
            raise Provider::AccountData::StaleWriter, "Transaction page authorization differs from its generation"
          end
        end
        raise Provider::AccountData::StaleWriter, "Generation has already been sealed" unless generation.fetching?
        sequence = 0
        accounts.with_verified_bindings(bindings.slice(*assembled.keys)) do |externals|
          assembled.each do |external_id, page|
            binding = bindings.fetch(external_id)
            external = externals.fetch(external_id)
            partition(page).each do |child|
              generation.ingestion_batches.create!(**batch_context(generation), external_account: external,
                generation_role: "account", stream: resource, scope_key: "account:#{external.id}",
                sequence: sequence, idempotency_key: batch_key(generation, "account", sequence),
                source_policy_version: binding["source_policy_version"], source_binding: binding, complete: true, mode: "delta",
                coverage: child.coverage.as_json, payload: Ingestion::Codec.dump(child))
              sequence += 1
            end
          end
        end
        generation.update!(status: "sealed", terminal_cursor: groups.last.next_cursor, sealed_at: Time.current, child_count: sequence)
      end
    end

    def partition(page)
      # Explicit removals concern exactly the supplied identities, so each chunk
      # is a complete bounded command. None can advance an account checkpoint or
      # authorize absence pruning; only the generation owns cursor promotion.
      changes = page.records.map { |record| [ :record, record ] } + page.removed_ids.map { |id| [ :removed, id ] }
      chunks = changes.each_slice(CHILD_SIZE).to_a
      chunks = [ [] ] if chunks.empty?
      chunks.each_with_index.map do |chunk, index|
        Provider::AccountData::Page.new(records: chunk.filter_map { |kind, value| value if kind == :record },
          removed_ids: chunk.filter_map { |kind, value| value if kind == :removed }, complete: true, mode: "delta",
          coverage: page.coverage.merge("partition_index" => index, "partition_count" => chunks.size), evidence: page.evidence)
      end
    end

    def removal_accounts(groups)
      ids = groups.flat_map(&:unassigned_removed_ids).uniq
      return {} if ids.empty?
      known = Hash.new { |mapping, id| mapping[id] = [] }
      # Native evidence is scoped by connection. A same-ID row in another family
      # or a guessed legacy Entry is never a routing decision.
      SourceRecord.joins(:external_account).where(kind: "transaction", external_id: ids,
        external_accounts: { provider_connection_id: connection.id, family_id: connection.family_id, identity_namespace: "connection" })
        .pluck("source_records.external_id", "external_accounts.external_id").each { |id, account_id| known[id] << account_id }
      wanted = ids.to_set
      groups.each do |group|
        group.account_pages.each do |account_id, page|
          (page.records.map { |record| record[:external_id] } + page.removed_ids).each do |id|
            known[id] << account_id if wanted.include?(id)
          end
        end
      end
      known.transform_values(&:uniq)
    end

    def apply_children(generation)
      bindings = generation.context_snapshot.fetch("accounts")
      generation.children.each do |batch|
        raise Provider::AccountData::IncompletePage, "Sync was cancelled" if sync.cancel_requested?
        next if batch.applied?
        external = connection.external_accounts.find(batch.external_account_id)
        binding = bindings.fetch(external.external_id)
        page = Ingestion::Codec.load(batch.payload)
        securities = if resource == "activities" && binding.fetch("publication") == "ledger" && page.records.any? { |record| record[:security] }
          Ingestion::SecurityResolver.new(account: external.current_account).resolve(page)
        end
        fenced do
          assert_checkpoint!(generation)
          accounts.with_verified_binding(external, binding) do |locked_external|
            batch.reload
            next if batch.applied?
            if binding.fetch("publication") == "ledger"
              arguments = { external_account: locked_external, batch: batch }
              arguments[:securities] = securities if securities
              @ledger_writer.new(**arguments).apply(page, allow_absence: false)
            else
              Ingestion::UnpublishedObservations.new(external_account: locked_external, batch: batch).apply(page)
            end
            batch.update!(status: "applied", applied_at: Time.current, error_code: nil)
          end
        end
      rescue StandardError => error
        # The fence has unwound here: diagnostics survive the failed child
        # transaction and cannot accidentally commit its partial ledger writes.
        capture_child_failure(error, generation: generation, batch: batch)
        raise
      end
    end

    def capture_child_failure(error, generation:, batch:)
      error_class = error.class.name.to_s
      error_class = "StandardError" unless error_class.size <= 200 && error_class.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)
      link = AccountProvider.find_by(external_account_id: batch.external_account_id, family_id: connection.family_id)
      DebugLogEntry.capture(category: "provider_sync_error", level: "error", message: "Transaction generation child failed",
        source: self.class.name, provider_key: connection.provider_key, family: connection.family, account_provider: link,
        metadata: { provider_connection_id: connection.id, sync_id: generation.sync_id, generation_id: generation.id,
          batch_id: batch.id, external_account_id: batch.external_account_id, error_class: error_class })
    rescue StandardError
      # Resolving diagnostic associations can also fail during a database outage.
      # Keep the original publication error as the worker's failure.
      nil
    end

    def promote(generation)
      fenced do
        generation.reload
        assert_checkpoint!(generation)
        unless generation.sealed? && generation.children.count == generation.child_count && !generation.children.where.not(status: "applied").exists?
          raise Provider::AccountData::IncompletePage, "Transaction generation still has unapplied accounts"
        end
        bindings = generation.context_snapshot.fetch("accounts")
        child_account_ids = generation.children.reorder(nil).distinct.pluck(:external_account_id).to_set
        participating = bindings.select { |_id, binding| child_account_ids.include?(binding.fetch("external_account_id")) }
        unless participating.size == child_account_ids.size
          raise Provider::AccountData::StaleWriter, "Generation child has no captured account binding"
        end
        accounts.with_verified_bindings(participating) do |externals|
          externals.each_value do |external|
            binding = bindings.fetch(external.external_id)
            retained_changes = generation.children.where(external_account_id: external.id).any? do |batch|
              page = Ingestion::Codec.load(batch.payload)
              page.records.any? || page.removed_ids.any?
            end
            if resource == "transactions" && binding.fetch("publication") == "retained" && retained_changes
              external.update!(transaction_backfill_required: true)
            end
          end
          generation.update!(status: "applied", applied_at: Time.current)
          current = checkpoint || connection.provider_sync_checkpoints.build(stream: resource, scope_key: "connection")
          current.assign_attributes(provider_sync_generation: generation, ingestion_batch: nil, cursor: generation.terminal_cursor,
            state: { "generation_id" => generation.id }, covered_through: [ current.covered_through, generation.sync.created_at ].compact.max)
          current.save!
        end
      end
    end

    def assert_checkpoint!(generation, pending_capture: nil)
      if resumable?
        captures = load_groups(generation).map { |group| group.evidence.fetch(Provider::AccountData::RequestGrant::EVIDENCE_KEY) }
        captures << pending_capture if pending_capture
        Provider::AccountData::RequestGrant.verify_chain!(connection: connection, initial_snapshot: generation.context_snapshot["request_grant"],
          captures: captures, require_runtime_inputs: @request_grant.runtime_inputs?, scope_sync: sync,
          generation: generation, current_snapshot: @request_grant.snapshot)
      else
        Provider::AccountData::RequestGrant.verify_snapshot!(connection: connection, snapshot: generation.context_snapshot["request_grant"],
          require_runtime_inputs: @request_grant.runtime_inputs?, scope_sync: sync)
      end
      expected_grant = generation.context_snapshot.fetch("connection_grant")
      current_grant = connection_grant
      if resumable?
        expected_grant = expected_grant.except("credential_revision")
        current_grant = current_grant.except("credential_revision")
      end
      unless expected_grant == current_grant
        raise Provider::AccountData::StaleWriter, "Connection authorization changed during the generation"
      end
      current = checkpoint
      captured = generation.context_snapshot.fetch("checkpoint")
      unless current&.id == captured["id"] && current&.lock_version == captured["lock_version"] && current&.cursor == generation.start_cursor
        raise Provider::AccountData::StaleWriter, "Committed transaction cursor changed during the generation"
      end
    end

    def load_groups(generation)
      sizes = generation.pages.limit(Ingestion::TransactionGroupAssembler::MAX_PAGES + 1).pluck(:id, Arel.sql("octet_length(payload)"))
      if sizes.size > Ingestion::TransactionGroupAssembler::MAX_PAGES || sizes.sum { |_id, bytes| bytes.to_i } > MAX_STORED_BYTES
        raise Provider::AccountData::IncompletePage, "Connection generation exceeds its captured byte or page bound"
      end
      decoded_bytes = 0
      expected = generation.start_cursor
      seen = Set.new
      groups = sizes.each_with_index.map do |(id, _bytes), index|
        batch = generation.pages.find(id)
        decoded_bytes += JSON.generate(batch.payload).bytesize
        raise Provider::AccountData::IncompletePage, "Connection generation exceeds its decoded byte bound" if decoded_bytes > MAX_DECODED_BYTES
        group = Ingestion::TransactionGroupCodec.load(batch.payload)
        unless batch.sequence == index && batch.stream == group_stream && group.resource == resource &&
            group.generation_id == generation.id && group.start_cursor == generation.start_cursor &&
            group.request_cursor == expected && seen.add?(expected) && (!group.complete? || index == sizes.size - 1) &&
            (group.complete? || !seen.include?(group.next_cursor))
          raise Provider::AccountData::InvalidResponse, "Captured generation has a broken page chain"
        end
        expected = group.next_cursor
        group
      end
      raise Provider::AccountData::InvalidResponse, "Captured generation page count disagrees" unless groups.size == generation.page_count
      groups
    end

    def connection_grant
      # Direct-token generations pin this revision exactly. Resumable activity
      # generations prove every revision separately through the request chain.
      { "external_id" => connection.external_id, "region" => connection.region, "environment" => connection.environment,
        "credential_revision" => connection.credential_revision }
    end

    def abandon(generation, code)
      fenced do
        generation.reload
        generation.update!(status: "abandoned", error_code: code) if generation.fetching?
      end
    end

    def batch_context(generation)
      { family: connection.family, provider_connection: connection, sync: generation.sync, origin_kind: "provider",
        writer_epoch: generation.writer_epoch, ruleset_snapshot: {} }
    end

    def batch_key(generation, role, sequence)
      Digest::SHA256.hexdigest([ generation.id, role, sequence ].join(":"))
    end
end
