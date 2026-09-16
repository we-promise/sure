require "test_helper"
require_relative "../../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::Akahu::CutoverHistoryTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  History = Provider::AccountData::Akahu::CutoverHistory
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
    Provider::Akahu.expects(:new).never
    clear_enqueued_jobs
  end
  teardown { clear_enqueued_jobs }

  test "empty and nil copied caches retain full history despite previous successful syncs" do
    [ [], nil ].each do |rows|
      with_history_source(rows: rows) do |context|
        context.item.syncs.create!(status: "completed", completed_at: 2.days.ago)
        before = retained_state(context)
        result = nil
        queries = capture_sql_queries { result = verify_result(context) }

        assert_equal({ context.external.id => nil }, result.account_starts)
        assert result.frozen?
        assert result.account_starts.frozen?
        assert_equal before, retained_state(context)
        assert_empty queries.grep(/\A(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\b/i)
      end
    end
  end

  test "stable posted identity retains its financial UUIDs and needs no inferred history floor" do
    with_history_source(rows: [ transaction ]) do |context|
      publish_identities(context)
      entry = context.account.entries.sole
      ids = [ entry.id, entry.entryable_id ]
      context.item.syncs.create!(status: "completed", completed_at: 300.days.ago)
      before = retained_state(context)

      assert_nil verify_history(context)
      assert_equal ids, [ entry.reload.id, entry.entryable_id ]
      assert_equal BigDecimal("12.34"), entry.amount
      assert_equal "akahu_retained-transaction", entry.external_id
      assert_equal before, retained_state(context)
    end
  end

  test "retained JSON numeric amounts match the original legacy decimal conversion" do
    with_history_source(rows: [ transaction("amount" => -12.34) ]) do |context|
      publish_identities(context)
      before = retained_state(context)

      assert_nil verify_history(context)
      assert_equal BigDecimal("12.34"), context.account.entries.sole.amount
      assert_equal before, retained_state(context)
    end
  end

  test "source start overrides item start and older cache without widening sibling windows" do
    item_start = Date.new(2025, 1, 2)
    source_start = Date.new(2026, 8, 1)
    with_history_source(rows: [ transaction ], item_start: item_start, source_start: source_start) do |context|
      sibling = context.item.akahu_accounts.create!(account_id: "akahu-sibling", name: "Unlinked sibling",
        currency: "NZD", raw_transactions_payload: [])
      recopy(context)
      publish_identities(context)
      external = context.external.provider_connection.external_accounts.find_by!(external_id: sibling.account_id)
      result = verify_result(context)

      assert_equal({ context.external.id => source_start, external.id => item_start }, result.account_starts)
      assert result.account_starts.values.all?(&:frozen?)
      assert_equal source_start, context.external.reload.sync_start_date
      assert_equal item_start, context.external.provider_connection.reload.sync_start_date
    end
  end

  test "item start applies to every unconfigured account including a nil-cache unlinked sibling" do
    start = Date.new(2026, 7, 1)
    with_history_source(item_start: start) do |context|
      source = context.item.akahu_accounts.create!(account_id: "akahu-sibling", name: "Sibling", currency: "NZD",
        raw_transactions_payload: nil)
      recopy(context)
      external = context.external.provider_connection.external_accounts.find_by!(external_id: source.account_id)

      assert_equal({ context.external.id => start, external.id => start }, verify_result(context).account_starts)
    end
  end

  test "post-bootstrap presentation economic overrides and protections survive verification" do
    with_history_source(rows: [ transaction ]) do |context|
      publish_identities(context)
      entry = context.account.entries.sole
      entry.update!(name: "User description", notes: "User note", amount: 99,
        date: Date.new(2020, 1, 8), user_modified: true, import_locked: true,
        locked_attributes: { "name" => true, "notes" => true, "amount" => true, "date" => true })
      before = retained_state(context)

      assert_nil verify_history(context)
      assert_equal before, retained_state(context)
    end
  end

  test "stable pending identity must match its signed original pending state" do
    with_history_source(rows: [ transaction("_pending" => true) ]) do |context|
      publish_identities(context)
      assert_nil verify_history(context)
      entry = context.account.entries.sole
      entry.transaction.update!(extra: entry.transaction.extra.deep_merge("akahu" => { "pending" => false }))
      before = retained_state(context)

      assert_raises(History::Conflict) { verify_history(context) }
      assert_equal before, retained_state(context)
    end
  end

  test "a collision-free idless pending cache uses its signed original zero occurrence" do
    with_history_source(rows: [ transaction.except("_id").merge("_pending" => true) ]) do |context|
      publish_identities(context)
      assert_match(/\Aakahu_pending_/, context.account.entries.sole.external_id)
      before = retained_state(context)

      assert_nil verify_history(context)
      assert_equal before, retained_state(context)
    end
  end

  test "signed retired stable pending alias is an explicit disposition but a posted alias is not" do
    [ true, false ].each do |pending|
      with_history_source(rows: [ transaction("_pending" => pending) ], import: false) do |context|
        record = Provider::AccountData::Akahu.new(client: nil, timezone: context.family.timezone)
          .normalize_transaction(transaction("_id" => "current-booked"), account: { external_id: "akahu-remote", currency: "NZD" })
        entry = identity_entry(context, external_id: record[:external_id], currency: record[:currency],
          date: record[:date], amount: record[:amount], name: record[:name], notes: record[:metadata][:notes],
          extra: record[:metadata][:extra].deep_stringify_keys.merge("auto_claimed_pending_ids" => [ "akahu_retained-transaction" ]))
        publish_identities(context)
        before = retained_state(context)

        if pending
          assert_nil verify_history(context)
        else
          assert_raises(History::Conflict) { verify_history(context) }
        end
        assert_equal "akahu_current-booked", entry.reload.external_id
        assert_equal before, retained_state(context)
      end
    end
  end

  test "deleted financial entries and withdrawn observations require explicit disposition" do
    %i[deleted_entry withdrawn_observation].each do |change|
      with_history_source(rows: [ transaction ]) do |context|
        publish_identities(context)
        if change == :deleted_entry
          context.account.entries.sole.destroy!
        else
          SourceRecord.where(external_account: context.external).sole.update!(withdrawn: true)
        end
        before = retained_state(context)

        assert_raises(History::Conflict) { verify_history(context) }
        assert_equal before, retained_state(context)
      end
    end
  end

  test "a stable ID without signed financial provenance cannot be inferred from matching values" do
    [ false, true ].each do |imported|
      with_history_source(rows: [ transaction ], import: imported) do |context|
        publish_identities(context) unless imported
        before = retained_state(context)

        assert_raises(History::Conflict) { verify_history(context) }
        assert_equal before, retained_state(context)
      end
    end
  end

  test "pre-bootstrap economic presentation and source metadata differences remain unresolved" do
    %i[amount currency date name notes metadata].each do |change|
      with_history_source(rows: [ transaction ]) do |context|
        entry = context.account.entries.sole
        case change
        when :amount then entry.update!(amount: 99)
        when :currency then entry.update!(currency: "USD")
        when :date then entry.update!(date: Date.new(2020, 1, 8))
        when :name then entry.update!(name: "Different name")
        when :notes then entry.update!(notes: "Different note")
        when :metadata then entry.transaction.update!(extra: entry.transaction.extra.deep_merge("akahu" => { "reference" => "changed" }))
        end
        publish_identities(context)
        before = retained_state(context)

        assert_raises(History::Conflict, change.to_s) { verify_history(context) }
        assert_equal before, retained_state(context)
      end
    end
  end

  test "recopied later cache revision cannot pass on an earlier posting of the same ID" do
    with_history_source(rows: [ transaction ]) do |context|
      context.source.update!(raw_transactions_payload: [ transaction("amount" => "-56.78") ])
      recopy(context)
      publish_identities(context)
      before = retained_state(context)

      assert_raises(History::Conflict) { verify_history(context) }
      assert_equal before, retained_state(context)
    end
  end

  test "unknown duplicate malformed and foreign-account cached rows refuse" do
    caches = [ {}, [ nil ], [ transaction.except("_account") ], [ transaction("_account" => "other-account") ],
      [ transaction.except("amount") ], [ transaction("amount" => "not-a-decimal") ],
      [ transaction.except("date") ], [ transaction("date" => "not-a-date") ],
      [ transaction, transaction ], [ transaction.except("_id") ] ]
    caches.each do |rows|
      with_history_source(rows: rows, import: false) do |context|
        publish_identities(context)
        before = retained_state(context)

        assert_raises(History::Conflict) { verify_history(context) }
        assert_equal before, retained_state(context)
      end
    end
  end

  test "only empty or nil unlinked caches can remain discovery-only" do
    [ [], nil, [ transaction ] ].each do |rows|
      with_history_source(rows: rows, linked: false, import: false) do |context|
        before = retained_state(context)
        if rows.blank?
          assert_equal({ context.external.id => nil }, verify_result(context).account_starts)
        else
          assert_raises(History::Conflict) { verify_history(context) }
        end
        assert_equal before, retained_state(context)
      end
    end
  end

  test "post-copy cache and configured window changes refuse a stale archive" do
    %i[cache item_start source_start external_start].each do |change|
      with_history_source do |context|
        case change
        when :cache then context.source.update!(raw_transactions_payload: [ transaction ])
        when :item_start then context.item.update!(sync_start_date: Date.new(2026, 8, 1))
        when :source_start then context.source.update!(sync_start_date: Date.new(2026, 8, 1))
        when :external_start then context.external.update!(sync_start_date: Date.new(2026, 8, 1))
        end
        before = retained_state(context)

        assert_raises(History::Conflict, change.to_s) { verify_history(context) }
        assert_equal before, retained_state(context)
      end
    end
  end

  test "missing copied source and newly discovered uncopied source refuse incomplete inventory" do
    %i[missing added].each do |change|
      with_history_source(linked: false) do |context|
        if change == :missing
          context.source.delete
        else
          context.item.akahu_accounts.create!(account_id: "uncopied", name: "Uncopied", currency: "NZD", raw_transactions_payload: [])
        end
        before = retained_state(context)

        assert_raises(History::Conflict) { verify_history(context) }
        assert_equal before, retained_state(context)
      end
    end
  end

  test "current financial account currency drift cannot adopt the original proof" do
    with_history_source(rows: [ transaction ]) do |context|
      publish_identities(context)
      context.account.update!(currency: "USD")
      before = retained_state(context)

      assert_raises(History::Conflict) { verify_history(context) }
      assert_equal before, retained_state(context)
    end
  end

  test "account row and byte budgets refuse a represented cache without mutations" do
    with_history_source(rows: [ transaction ]) do |context|
      publish_identities(context)
      before = retained_state(context)
      %i[MAX_ACCOUNTS MAX_RECORDS MAX_BYTES MAX_IDENTITY_BYTES].each do |constant|
        with_history_limit(constant, 0) { assert_raises(History::Conflict) { verify_history(context) } }
      end
      assert_equal before, retained_state(context)
    end
  end

  test "exclusive final transaction and exact family are mandatory" do
    with_history_source do |context|
      assert_raises(ArgumentError) { verifier(context).verify! }
      ApplicationRecord.transaction { assert_raises(Fence::InvalidSource) { verifier(context).verify! } }
      Fence.with_exclusive(context.item) do
        ApplicationRecord.transaction do
          assert_raises(History::Conflict) do
            History.new(item: context.item, connection: context.external.provider_connection, family: families(:empty)).verify!
          end
        end
      end
    end
  end

  test "disabled initial connection and quiesced zero-epoch ownership are required" do
    %i[control_state control_epoch connection_state connection_epoch].each do |change|
      with_history_source do |context|
        case change
        when :control_state then context.control.update!(state: "shadow")
        when :control_epoch then context.control.update!(writer_epoch: 1)
        when :connection_state then context.external.provider_connection.update!(status: "good")
        when :connection_epoch then context.external.provider_connection.update!(writer_epoch: 1)
        end
        before = retained_state(context)

        assert_raises(History::Conflict, change.to_s) { verify_history(context) }
        assert_equal before, retained_state(context)
      end
    end
  end

  test "real preparation and cutover retain explicit full-history metadata and replay the original Sync" do
    with_history_source(rows: [ transaction ]) do |context|
      original_policy = Account::SourcePolicy.active.find_by!(account: context.account, resource: "transactions").attributes
      finish_preparation(context)
      policies = Account::SourcePolicy.active.where(account: context.account).order(:resource).map(&:attributes)
      assert_equal %w[balances transactions], policies.map { |policy| policy.fetch("resource") }
      assert_equal original_policy, policies.find { |policy| policy.fetch("resource") == "transactions" }
      before = retained_state(context).slice(:financial, :observations, :postings, :batches)
      Provider::AccountData::Akahu.stubs(:native_ready?).returns(true)
      command = cutover(context)
      result = nil

      queries = capture_sql_queries do
        assert_enqueued_with(job: SyncJob) { result = command.call }
      end

      refute result.replayed
      connection = context.external.provider_connection.reload
      sync = connection.syncs.sole
      assert_equal result.sync_id, sync.id
      assert sync.pending?
      assert_nil sync.window_start_date
      assert_nil sync.window_end_date
      assert connection.good?
      assert context.control.reload.active?
      assert_equal 1, connection.writer_epoch
      assert_equal 1, context.control.writer_epoch
      assert_nil context.external.reload.metadata.fetch("akahu_initial_history_start")
      receipt = context.control.audit_results.fetch("native_cutover")
      assert_equal({ context.external.id => nil }, receipt.fetch("account_starts"))
      assert_equal context.control.preparation_state.fetch("run_id"), receipt.fetch("preparation_run_id")
      assert_equal context.control.high_water_mark.fetch("copy_run_id"), receipt.fetch("copy_run_id")
      assert_equal policies, Account::SourcePolicy.active.where(account: context.account).order(:resource).map(&:attributes)
      assert_equal before, retained_state(context).slice(:financial, :observations, :postings, :batches)
      assert_no_financial_sql(queries)
      committed = retained_state(context)
      original_sync = sync.attributes
      replay = nil

      assert_enqueued_with(job: SyncJob) { replay = command.call }

      assert replay.replayed
      assert_equal result.sync_id, replay.sync_id
      assert_equal original_sync, sync.reload.attributes
      assert_equal 1, connection.syncs.count
      assert_equal committed, retained_state(context)
    end
  end

  test "production readiness remains false and refuses cutover before provider construction" do
    with_history_source do |context|
      finish_preparation(context)
      before = retained_state(context)
      refute Provider::AccountData::Akahu.native_ready?

      assert_no_enqueued_jobs do
        assert_raises(Provider::AccountData::UnsupportedCapability) { cutover(context).call }
      end

      assert_equal before, retained_state(context)
      assert context.control.reload.quiescing?
      assert context.external.provider_connection.reload.disabled?
      assert_empty context.external.provider_connection.syncs
    end
  end

  private
    def transaction(changes = {})
      { "_id" => "retained-transaction", "_account" => "akahu-remote", "amount" => "-12.34", "currency" => "NZD",
        "date" => "2020-01-02", "description" => "Retained coffee", "type" => "DEBIT",
        "meta" => { "reference" => "Original reference", "particulars" => "Original particulars", "code" => "CODE" } }.merge(changes)
    end

    def with_history_source(rows: [], item_start: nil, source_start: nil, linked: true, import: true)
      with_provider_encryption do
        family = families(:dylan_family)
        timestamps = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
        item = AkahuItem.create!(family: family, name: "Akahu cutover", app_token: "private-app-token",
          user_token: "private-user-token", sync_start_date: item_start)
        account = family.accounts.create!(name: "Retained Akahu", currency: "NZD", balance: 100, accountable: Depository.new)
        begin
          source = item.akahu_accounts.create!(account_id: "akahu-remote", name: "Akahu source", currency: "NZD",
            raw_transactions_payload: rows, sync_start_date: source_start)
          link = AccountProvider.create!(account: account, provider: source) if linked
          Array(rows).each { |raw| AkahuEntry::Processor.new(raw, akahu_account: source).process } if import && linked
          copier = Provider::AccountData::MigrationCopier.new(provider_key: "akahu", legacy_item_id: item.id, batch_size: 1)
          control = nil
          20.times do
            control = copier.run_quiesced.reload
            break if control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", control.high_water_mark["phase"]
          external = control.provider_connection.external_accounts.sole
          mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
          Account::SourcePolicy.select!(account: account, account_provider: link.reload, resource: "transactions") if link
          yield IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: source, account: account,
            link: link, copier: copier, control: control, mapping: mapping, external: external)
        ensure
          connection = ProviderConnection.find_by(id: control&.provider_connection_id)
          Sync.where(syncable_type: "ProviderConnection", syncable_id: connection.id).delete_all if connection
          Sync.where(syncable_type: "AkahuItem", syncable_id: item.id).delete_all
          cleanup_identity_source(item, account)
          Family.where(id: family.id).update_all(timestamps)
        end
      end
    end

    def recopy(context)
      control = context.copier.run_quiesced(restart: true)
      20.times do
        break if control.reload.high_water_mark["phase"] == "verified"
        control = context.copier.run_quiesced
      end
      assert_equal "verified", control.reload.high_water_mark["phase"]
      context.mapping.reload
      context.external.reload
      context.link.reload if context.link
    end

    def publish_identities(context)
      publisher = Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family)
      result = nil
      10.times do
        result = publisher.run
        break if result.verified?
      end
      assert result.verified?
    end

    def finish_preparation(context)
      150.times do
        result = Provider::AccountData::MigrationPreparation.new(provider_key: "akahu", legacy_item_id: context.item.id,
          family: context.family, page_size: 1).run
        return result if result.awaiting_acceptance?
      end
      flunk "Preparation did not complete its bounded verification calls"
    end

    def cutover(context)
      Provider::AccountData::MigrationCutover.new(provider_key: "akahu", legacy_item_id: context.item.id,
        family: context.family, page_size: 1)
    end

    def verifier(context)
      History.new(item: context.item, connection: context.external.provider_connection, family: context.family)
    end

    def verify_result(context)
      Fence.with_exclusive(context.item) do
        ApplicationRecord.transaction(requires_new: true) { verifier(context).verify! }
      end
    end

    def verify_history(context)
      verify_result(context).account_starts.fetch(context.external.id)
    end

    def retained_state(context)
      { financial: identity_financial_snapshot(context), control: context.control.reload.attributes,
        connection: context.external.provider_connection.reload.attributes,
        observations: SourceRecord.where(external_account: context.external).order(:id).map(&:attributes),
        postings: EntrySource.where(source_record_id: SourceRecord.where(external_account: context.external).select(:id)).order(:id).map(&:attributes),
        batches: context.external.provider_connection.ingestion_batches.order(:id).pluck(:id, Arel.sql("payload::text")),
        checkpoints: context.external.provider_connection.provider_sync_checkpoints.order(:id).map(&:attributes) }
    end

    def with_history_limit(name, value)
      previous = History.const_get(name)
      History.send(:remove_const, name)
      History.const_set(name, value)
      yield
    ensure
      History.send(:remove_const, name)
      History.const_set(name, previous)
    end
end
