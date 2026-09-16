require "test_helper"
require_relative "../../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::Mercury::CutoverHistoryTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  History = Provider::AccountData::Mercury::CutoverHistory
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
    Provider::Mercury.expects(:new).never
    clear_enqueued_jobs
  end
  teardown { clear_enqueued_jobs }

  test "empty caches preserve the creation-based first window and ignore prior item success" do
    [ 3, 300 ].each do |age|
      with_history_source(created_at: age.days.ago) do |context|
        context.item.syncs.create!(status: "completed", completed_at: 250.days.ago)
        expected = [ context.source.created_at.getutc.to_date - 7.days, Time.current.getutc.to_date - 90.days ].max
        before = retained_state(context)
        queries = capture_sql_queries { assert_equal expected, verify_history(context) }

        assert_equal before, retained_state(context)
        assert_empty queries.grep(/\A(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\b/i)
      end
    end
  end

  test "nonempty cache uses latest completed item overlap before its own earlier cached dates" do
    recent = 10.days.ago.getutc.iso8601
    with_history_source(rows: [ transaction("createdAt" => recent, "postedAt" => recent) ]) do |context|
      publish_identities(context)
      assert_equal Time.current.getutc.to_date - 90.days, verify_history(context)
      context.item.syncs.create!(status: "completed", completed_at: 150.days.ago)
      context.item.syncs.load
      newer = context.item.syncs.create!(status: "completed", completed_at: 250.days.ago)

      assert_equal newer.completed_at.getutc.to_date - 7.days, verify_history(context)
    end
  end

  test "signed original numeric cache widens only its account and preserves user edits" do
    with_history_source(rows: [ transaction("amount" => -12.34) ]) do |context|
      publish_identities(context)
      entry = context.account.entries.sole
      entry.update!(name: "User description", notes: "User notes", user_modified: true, import_locked: true)
      before = retained_state(context)

      assert_equal Date.new(2020, 1, 2), verify_history(context)
      assert_equal before, retained_state(context)
      assert_equal "mercury_retained-transaction", entry.reload.external_id
    end
  end

  test "copied explicit item start deliberately takes precedence over legacy heuristics and old cache" do
    start = Time.utc(2026, 8, 1, 15, 30)
    with_history_source(rows: [ transaction ], item_start: start) do |context|
      publish_identities(context)
      context.item.syncs.create!(status: "completed", completed_at: 300.days.ago)
      assert_equal start.to_date, verify_history(context)
      assert_equal start.to_date, context.external.provider_connection.sync_start_date
    end
  end

  test "a recent empty sibling keeps its own bound despite older represented history" do
    with_history_source(rows: [ transaction ]) do |context|
      sibling = context.family.accounts.create!(name: "Mercury sibling", currency: "USD", balance: 0, accountable: Depository.new)
      begin
        source = context.item.mercury_accounts.create!(account_id: "sibling", name: "Sibling", currency: "USD",
          raw_transactions_payload: [], created_at: 2.days.ago)
        AccountProvider.create!(account: sibling, provider: source)
        recopy(context)
        publish_identities(context)
        external = context.external.provider_connection.external_accounts.find_by!(external_id: source.account_id)

        result = verify_result(context)

        assert_equal({ context.external.id => Date.new(2020, 1, 2), external.id => source.created_at.getutc.to_date - 7.days }, result.account_starts)
        assert result.frozen?
        assert result.account_starts.frozen?
      ensure
        Account::SourcePolicy.where(account_id: sibling.id).delete_all
        AccountProvider.where(account_id: sibling.id).delete_all
        sibling.reload.destroy!
      end
    end
  end

  test "pending same-ID cache requires the corresponding signed pending financial state" do
    with_history_source(rows: [ transaction("status" => "pending", "postedAt" => nil) ]) do |context|
      publish_identities(context)
      assert_equal Date.new(2020, 1, 2), verify_history(context)
      context.account.entries.sole.transaction.update!(extra: { "mercury" => { "pending" => false } })
      assert_raises(History::Conflict) { verify_history(context) }
    end
  end

  test "known failed rows without financial identity are explicit nonfinancial dispositions" do
    [ true, false ].each do |linked|
      with_history_source(rows: [ transaction("status" => "failed") ], linked: linked) do |context|
        publish_identities(context) if linked
        before = retained_state(context)
        assert_equal Date.new(2020, 1, 2), verify_history(context)
        assert_equal before, retained_state(context)
        assert_empty context.account.entries
        assert_empty SourceRecord.where(external_account: context.external)
      end
    end
  end

  test "a failed cache row cannot suppress a prior posting pending identity or retired alias" do
    [ :posted, :pending, :alias ].each do |state|
      with_history_source(rows: [ transaction("status" => "failed") ]) do |context|
        extra = { "mercury" => { "pending" => state == :pending } }
        extra["auto_claimed_pending_ids"] = [ "mercury_retained-transaction" ] if state == :alias
        identity_entry(context, external_id: state == :alias ? "mercury_new" : "mercury_retained-transaction", extra: extra)
        publish_identities(context)
        before = retained_state(context)

        assert_raises(History::Conflict, state.to_s) { verify_history(context) }
        assert_equal before, retained_state(context)
      end
    end
  end

  test "cache-only rows and pre-bootstrap economic differences remain unresolved" do
    [ :missing, :amount, :currency, :date, :name, :notes, :metadata ].each do |change|
      with_history_source(rows: [ transaction ], import: change != :missing) do |context|
        unless change == :missing
          entry = context.account.entries.sole
          case change
          when :amount then entry.update!(amount: 99)
          when :currency then entry.update!(currency: "EUR")
          when :date then entry.update!(date: Date.new(2020, 1, 4))
          when :name then entry.update!(name: "Before-bootstrap override")
          when :notes then entry.update!(notes: "Before-bootstrap note")
          when :metadata then entry.transaction.update!(extra: { "mercury" => { "pending" => false, "kind" => "other" } })
          end
        end
        publish_identities(context)
        before = retained_state(context)

        assert_raises(History::Conflict, change.to_s) { verify_history(context) }
        assert_equal before, retained_state(context)
      end
    end
  end

  test "malformed partial duplicate and foreign-account caches refuse without inferred coverage" do
    rows = [ [ nil ], [ transaction.except("id") ], [ transaction.except("amount") ],
      [ transaction.except("status") ], [ transaction("createdAt" => nil, "postedAt" => nil) ],
      [ transaction, transaction ], [ transaction("accountId" => "foreign") ],
      [ transaction("status" => "failed", "accountId" => "foreign") ] ]
    rows.each do |cache|
      with_history_source(rows: cache, import: false) do |context|
        publish_identities(context)
        assert_raises(History::Conflict) { verify_history(context) }
      end
    end
  end

  test "unlinked live caches need explicit disposition while empty sources keep discovery bounds" do
    [ [], [ transaction ] ].each do |rows|
      with_history_source(rows: rows, linked: false, import: false) do |context|
        if rows.empty?
          assert_equal context.source.created_at.getutc.to_date - 7.days, verify_history(context)
        else
          assert_raises(History::Conflict) { verify_history(context) }
        end
      end
    end
  end

  test "earliest source timestamps use UTC rather than the displayed family date" do
    raw = transaction("createdAt" => "2020-01-02T00:15:00+02:00", "postedAt" => "2020-01-02T23:30:00-05:00")
    with_history_source(rows: [ raw ]) do |context|
      publish_identities(context)
      assert_equal Date.new(2020, 1, 1), verify_history(context)
    end
  end

  test "post-copy cache creation-time and explicit-start drift refuse" do
    [ :cache, :creation, :start ].each do |change|
      with_history_source do |context|
        case change
        when :cache then context.source.update!(raw_transactions_payload: [ transaction ])
        when :creation then context.source.update!(created_at: 300.days.ago)
        when :start then context.item.update!(sync_start_date: 100.days.ago)
        end
        assert_raises(History::Conflict) { verify_history(context) }
      end
    end
  end

  test "exclusive final transaction and exact family are required" do
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

  test "account row and byte budgets refuse before mutation" do
    with_history_source(rows: [ transaction ]) do |context|
      before = retained_state(context)
      %i[MAX_ACCOUNTS MAX_RECORDS MAX_BYTES].each do |constant|
        with_history_limit(constant, 0) { assert_raises(History::Conflict) { verify_history(context) } }
      end
      assert_equal before, retained_state(context)
    end
  end

  private
    def transaction(changes = {})
      { "id" => "retained-transaction", "accountId" => "mercury-remote", "amount" => "-12.34", "status" => "sent",
        "bankDescription" => "Retained coffee", "kind" => "card", "note" => "Original note",
        "createdAt" => "2020-01-02T12:00:00Z", "postedAt" => "2020-01-03T12:00:00Z" }.merge(changes)
    end

    def with_history_source(rows: [], created_at: Time.current, item_start: nil, linked: true, import: true)
      with_provider_encryption do
        family = families(:dylan_family)
        timestamps = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
        item = MercuryItem.create!(family: family, name: "Mercury cutover", token: "private-test-token", sync_start_date: item_start)
        account = family.accounts.create!(name: "Retained Mercury", currency: "USD", balance: 100, accountable: Depository.new)
        begin
          source = item.mercury_accounts.create!(account_id: "mercury-remote", name: "Mercury source", currency: "USD",
            raw_transactions_payload: rows, created_at: created_at)
          link = AccountProvider.create!(account: account, provider: source) if linked
          rows.each { |raw| MercuryEntry::Processor.new(raw, mercury_account: source).process } if import && linked
          copier = Provider::AccountData::MigrationCopier.new(provider_key: "mercury", legacy_item_id: item.id, batch_size: 1)
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
          Sync.where(syncable_type: "MercuryItem", syncable_id: item.id).delete_all
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
