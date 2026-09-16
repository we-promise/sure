require "test_helper"
require_relative "../../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::Up::CutoverHistoryTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  History = Provider::AccountData::Up::CutoverHistory
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
    Provider::Up.expects(:new).never
  end

  test "empty copied history yields the native default without mutating ownership coverage or finance" do
    with_history_source do |context|
      before = retained_state(context)
      queries = capture_sql_queries { assert_equal Date.current - 90.days, verify_history(context) }

      assert_equal before, retained_state(context)
      assert_empty queries.grep(/\A(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\b/i)
    end
  end

  test "configured per-account start precedes item start and is not widened by retained cache" do
    with_history_source do |context|
      context.item.update!(sync_start_date: Date.current - 120.days)
      context.source.update!(sync_start_date: Date.current - 30.days)
      raw = transaction(context)
      prepare_cache(context, [ raw ])
      import_identity(context, raw)
      publish_identities(context)
      context.item.syncs.create!(status: "completed", completed_at: 250.days.ago)

      assert_equal Date.current - 30.days, verify_history(context)
    end
  end

  test "configured item start precedes default overlap and older cache dates" do
    with_history_source do |context|
      context.item.update!(sync_start_date: Date.current - 15.days)
      raw = transaction(context)
      prepare_cache(context, [ raw ])
      import_identity(context, raw)
      publish_identities(context)

      assert_equal Date.current - 15.days, verify_history(context)
    end
  end

  test "last completed legacy Sync overlap applies only to accounts with cached transactions" do
    with_history_source do |context|
      context.item.syncs.create!(status: "completed", completed_at: 250.days.ago)
      assert_equal Date.current - 90.days, verify_history(context)

      recent = 10.days.ago.getutc.iso8601
      raw = transaction(context, "createdAt" => recent, "settledAt" => recent)
      prepare_cache(context, [ raw ])
      import_identity(context, raw)
      publish_identities(context)

      # Deliberately load the old receiver's cache; the gate queries fresh Syncs.
      context.item.syncs.load
      newer = context.item.syncs.create!(status: "completed", completed_at: 300.days.ago)
      assert_equal newer.completed_at.getutc.to_date - 7.days, verify_history(context)
    end
  end

  test "each copied sibling receives its own immutable initial bound" do
    with_history_source do |context|
      sibling = context.family.accounts.create!(name: "Second Up account", currency: "USD", balance: 0,
        accountable: Depository.new, status: "active")
      begin
        source = context.item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Second source", currency: "USD",
          raw_transactions_payload: [], sync_start_date: Date.current - 500.days)
        AccountProvider.create!(account: sibling, provider: source)
        context.source.update!(sync_start_date: Date.current - 5.days)
        recopy(context)
        external = context.external.provider_connection.external_accounts.find_by!(external_id: source.account_id)

        result = verify_result(context)

        assert_equal({ context.external.id => Date.current - 5.days, external.id => Date.current - 500.days }, result.account_starts)
        assert result.frozen?
        assert result.account_starts.frozen?
        assert result.account_starts.values.all?(&:frozen?)
      ensure
        Account::SourcePolicy.where(account_id: sibling.id).delete_all
        AccountProvider.where(account_id: sibling.id).delete_all
        sibling.destroy!
      end
    end
  end

  test "recent legacy success does not reintroduce the ninety day default for a populated cache" do
    with_history_source do |context|
      recent = 1.day.ago.getutc.iso8601
      raw = transaction(context, "createdAt" => recent, "settledAt" => recent)
      prepare_cache(context, [ raw ])
      import_identity(context, raw)
      publish_identities(context)
      completed = context.item.syncs.create!(status: "completed", completed_at: 2.days.ago)

      assert_equal completed.completed_at.getutc.to_date - 7.days, verify_history(context)
    end
  end

  test "original creation and settlement timestamps widen the first read in UTC" do
    with_history_source do |context|
      raw = transaction(context, "createdAt" => "2020-01-02T00:30:00+11:00", "settledAt" => "2020-01-05T00:30:00+11:00")
      prepare_cache(context, [ raw ])
      import_identity(context, raw)
      publish_identities(context)

      assert_equal Date.new(2020, 1, 1), verify_history(context)
    end
  end

  test "current user financial and descriptive edits remain intact after original baseline capture" do
    with_history_source do |context|
      raw = transaction(context)
      prepare_cache(context, [ raw ])
      entry = import_identity(context, raw)
      publish_identities(context)
      entry.update!(amount: 999, name: "User description", notes: "User notes", user_modified: true)
      entry.transaction.update!(kind: "funds_movement", extra: entry.transaction.extra.merge("private" => "User value"))
      before = identity_financial_snapshot(context)

      verify_history(context)

      assert_equal before, identity_financial_snapshot(context)
    end
  end

  test "same provider ID without financial provenance refuses instead of assuming API recovery" do
    with_history_source do |context|
      raw = transaction(context)
      prepare_cache(context, [ raw ])
      import_identity(context, raw)

      assert_raises(History::Conflict) { verify_history(context) }
    end
  end

  test "cached current revision must match signed original values including pending status" do
    [ { amount: BigDecimal("90") }, { name: "Older provider name" }, { date: Date.new(2019, 1, 1) },
      { currency: "EUR" }, { notes: "Older provider message" }, { pending: true } ].each do |change|
      with_history_source do |context|
        raw = transaction(context)
        prepare_cache(context, [ raw ])
        import_identity(context, raw, **change)
        publish_identities(context)
        assert_raises(History::Conflict, change.inspect) { verify_history(context) }
      end
    end
  end

  test "cached provider metadata requires its original baseline while derived transaction kind may differ" do
    [ { "fx_from" => "EUR", "fx_amount" => "15.00" }, { "status" => "HELD" },
      { "category_id" => "unapplied-category" }, { "raw_text" => "unapplied-text" },
      { "transfer_account_id" => "unapplied-transfer" } ].each do |change|
      with_history_source do |context|
        raw = transaction(context)
        prepare_cache(context, [ raw ])
        entry = import_identity(context, raw)
        entry.transaction.update!(extra: { "up" => entry.transaction.extra.fetch("up").merge(change) })
        publish_identities(context)
        assert_raises(History::Conflict) { verify_history(context) }
      end
    end
    with_history_source do |context|
      raw = transaction(context)
      prepare_cache(context, [ raw ])
      import_identity(context, raw, kind: "funds_movement")
      publish_identities(context)
      verify_history(context)
    end
  end

  test "exact idless pending identity is supported without a fuzzy match" do
    with_history_source do |context|
      raw = transaction(context, "id" => nil, "status" => "HELD", "settledAt" => nil)
      prepare_cache(context, [ raw ])
      entry = import_identity(context, raw)
      assert_match(/\Aup_pending_/, entry.external_id)
      publish_identities(context)

      verify_history(context)
    end
  end

  test "signed retired pending alias is an explicit disposition but a settled alias is not" do
    [ "HELD", "SETTLED" ].each do |status|
      with_history_source do |context|
        raw = transaction(context, "id" => "old-pending", "status" => status)
        prepare_cache(context, [ raw ])
        import_identity(context, transaction(context, "id" => "current-booked"), aliases: [ "up_old-pending" ])
        publish_identities(context)

        if status == "HELD"
          verify_history(context)
        else
          assert_raises(History::Conflict) { verify_history(context) }
        end
      end
    end
  end

  test "deleted financial UUID or withdrawn observation requires explicit reconciliation" do
    [ :delete_entry, :withdraw_observation ].each do |disposition|
      with_history_source do |context|
        raw = transaction(context)
        prepare_cache(context, [ raw ])
        entry = import_identity(context, raw)
        publish_identities(context)
        if disposition == :delete_entry
          entry.destroy!
        else
          SourceRecord.find_by!(external_account: context.external).update!(withdrawn: true)
        end

        assert_raises(History::Conflict) { verify_history(context) }
      end
    end
  end

  test "post-bootstrap identity drift rejects while preserving original evidence" do
    with_history_source do |context|
      raw = transaction(context)
      prepare_cache(context, [ raw ])
      entry = import_identity(context, raw)
      publish_identities(context)
      entry.transaction.update!(extra: entry.transaction.extra.deep_merge("up" => { "pending" => true }))
      before = retained_state(context)

      assert_raises(History::Conflict) { verify_history(context) }
      assert_equal before, retained_state(context)
    end
  end

  test "unknown malformed duplicate and foreign-account cache rows refuse" do
    [ :unknown_status, :missing_date, :malformed_row, :duplicate, :foreign_account ].each do |case_name|
      with_history_source do |context|
        raw = transaction(context)
        rows = case case_name
        when :unknown_status then [ raw.merge("status" => "UNKNOWN") ]
        when :missing_date then [ raw.except("createdAt", "settledAt") ]
        when :malformed_row then [ "opaque row" ]
        when :duplicate then [ raw, raw ]
        when :foreign_account then [ raw.merge("account_id" => "another-account") ]
        end
        prepare_cache(context, rows)
        import_identity(context, raw)
        publish_identities(context)

        assert_raises(History::Conflict, case_name.to_s) { verify_history(context) }
      end
    end
  end

  test "unlinked empty sources remain discovery-only but nonempty cache refuses" do
    [ [], :nonempty ].each do |cache|
      with_history_source do |context|
        Account::SourcePolicy.where(account_id: context.account.id).delete_all
        context.link.delete
        raw = cache == :nonempty ? [ transaction(context) ] : []
        prepare_cache(context, raw)

        if raw.empty?
          assert_equal Date.current - 90.days, verify_history(context)
        else
          assert_raises(History::Conflict) { verify_history(context) }
        end
        assert_nil context.external.reload.current_account
      end
    end
  end

  test "current cache or configured date changes after copy refuse" do
    [ :cache, :configured_start ].each do |changed|
      with_history_source do |context|
        if changed == :cache
          context.source.update!(raw_transactions_payload: [ transaction(context) ])
        else
          context.item.update!(sync_start_date: Date.current - 200.days)
        end
        assert_raises(History::Conflict) { verify_history(context) }
      end
    end
  end

  test "family mismatch and missing exclusive final transaction cannot authorize verification" do
    with_history_source do |context|
      assert_raises(ArgumentError) { verifier(context).verify! }
      ApplicationRecord.transaction do
        assert_raises(Fence::InvalidSource) { verifier(context).verify! }
      end
      Fence.with_exclusive(context.item) do
        ApplicationRecord.transaction do
          assert_raises(History::Conflict) do
            History.new(item: context.item, connection: context.external.provider_connection, family: families(:empty)).verify!
          end
        end
      end
    end
  end

  test "account record and stored cache budgets refuse without any financial writes" do
    with_history_source do |context|
      with_history_limit(:MAX_ACCOUNTS, 0) { assert_raises(History::Conflict) { verify_history(context) } }
      raw = transaction(context)
      prepare_cache(context, [ raw ])
      before = identity_financial_snapshot(context)
      with_history_limit(:MAX_RECORDS, 0) { assert_raises(History::Conflict) { verify_history(context) } }
      with_history_limit(:MAX_BYTES, 1) { assert_raises(History::Conflict) { verify_history(context) } }
      assert_equal before, identity_financial_snapshot(context)
    end
  end

  private
    def with_history_source
      family = families(:dylan_family)
      timestamps = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
      with_identity_source do |context|
        begin
          yield context
        ensure
          Sync.where(syncable_type: "UpItem", syncable_id: context.item.id).delete_all
        end
      end
    ensure
      Family.where(id: family.id).update_all(timestamps) if family && timestamps
    end

    def transaction(context, changes = {})
      { "id" => "retained-transaction", "account_id" => context.source.account_id, "description" => "Retained coffee",
        "amount" => { "value" => "-12.34", "currencyCode" => "USD" }, "status" => "SETTLED",
        "createdAt" => "2020-01-02T12:00:00Z", "settledAt" => "2020-01-03T12:00:00Z" }.merge(changes)
    end

    def prepare_cache(context, rows)
      context.source.update!(raw_transactions_payload: rows)
      recopy(context)
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
      context.link.reload if AccountProvider.exists?(context.link.id)
    end

    def import_identity(context, raw, aliases: [], pending: nil, kind: nil, **overrides)
      record = Provider::AccountData::Up.new(client: nil, timezone: context.family.timezone)
        .normalize_transaction(raw, account: { external_id: context.source.account_id, currency: context.source.currency })
      extra = record[:metadata][:extra].deep_dup
      extra["up"]["pending"] = pending unless pending.nil?
      extra["auto_claimed_pending_ids"] = aliases if aliases.any?
      identity_entry(context, external_id: record[:external_id], name: record[:name], amount: record[:amount],
        currency: record[:currency], date: record[:date], notes: record[:metadata][:notes],
        entryable: Transaction.new(kind: kind || record[:metadata][:kind] || "standard", extra: extra), **overrides)
    end

    def publish_identities(context)
      publisher = Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family, page_size: 100)
      result = nil
      10.times do
        result = publisher.run
        break if result.verified?
      end
      assert result.verified?
    end

    def verifier(context)
      History.new(item: context.item, connection: context.external.provider_connection, family: context.family)
    end

    def verify_history(context)
      verify_result(context).account_starts.fetch(context.external.id)
    end

    def verify_result(context)
      Fence.with_exclusive(context.item) do
        ApplicationRecord.transaction(requires_new: true) { verifier(context).verify! }
      end
    end

    def retained_state(context)
      { financial: identity_financial_snapshot(context), control: context.control.reload.attributes,
        connection: context.external.provider_connection.reload.attributes,
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
