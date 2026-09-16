require "test_helper"
require_relative "../../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::Brex::CutoverHistoryTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  History = Provider::AccountData::Brex::CutoverHistory
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
    Provider::Brex.expects(:new).never
    Provider::AccountData::Brex.stubs(:native_ready?).returns(true)
    clear_enqueued_jobs
  end
  teardown { clear_enqueued_jobs }

  test "cash cache proves original values and UUIDs without changing later user edits" do
    with_history_source(rows: [ transaction ]) do |context|
      publish_identities(context)
      entry = context.account.entries.sole
      entry.update!(amount: 99, name: "User description", notes: "User notes", user_modified: true, import_locked: true)
      before = retained_state(context)
      result = nil
      queries = capture_sql_queries { result = verify_result(context) }

      assert_equal Date.new(2020, 1, 2), result.account_starts.fetch(context.external.id)
      assert result.frozen?
      assert result.account_starts.frozen?
      assert result.account_starts.keys.all?(&:frozen?)
      assert result.account_starts.values.all?(&:frozen?)
      assert_equal before, retained_state(context)
      assert_empty queries.grep(/\A(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\b/i)
      assert_equal entry.id, context.account.entries.sole.id
    end
  end

  test "company card aggregate and negative collection preserve one financial source" do
    rows = [ transaction("id" => "payment", "account_id" => "physical-card-2", "type" => "COLLECTION",
      "amount" => money(-2500), "card_id" => "physical-card-2") ]
    with_history_source(kind: "card", rows: rows) do |context|
      publish_identities(context)
      entry = context.account.entries.sole
      assert_equal "card_primary", context.external.external_id
      assert_equal BigDecimal("-25"), entry.amount
      assert_equal "cc_payment", entry.transaction.kind
      assert_equal BigDecimal("150"), context.source.current_balance
      assert_equal BigDecimal("850"), context.source.available_balance
      before = retained_state(context)

      assert_equal Date.new(2020, 1, 2), verify_history(context)

      assert_equal before, retained_state(context)
      assert_equal [ "card_primary" ], context.control.provider_connection.external_accounts.pluck(:external_id)
    end
  end

  test "native cash and card replay consume the original signed mapping without replacing protected UUIDs" do
    %w[cash card].each do |kind|
      raw = transaction("amount" => money(kind == "card" ? -2500 : 1234), "type" => kind == "card" ? "COLLECTION" : "PURCHASE")
      with_history_source(kind: kind, rows: [ raw ]) do |context|
        publish_identities(context)
        verify_history(context)
        entry = context.account.entries.sole
        observation = SourceRecord.find_by!(external_account: context.external, external_id: entry.external_id)
        posting = observation.entry_source
        proof = IngestionBatch.find(posting.bootstrap_batch_id)
        original_proof = [ posting.attributes, proof.read_attribute_before_type_cast("payload") ]
        original_ids = [ entry.id, entry.entryable_id, observation.id, posting.id ]
        entry.update!(amount: 77, name: "Protected name", notes: "Protected note", user_modified: true, import_locked: true)
        financial = entry.reload.attributes.except("updated_at")
        transaction_state = entry.transaction.reload.attributes

        client = mock("Brex native transaction transport")
        if kind == "card"
          client.expects(:get_primary_card_transactions_page).with(cursor: nil, start_date: "2020-01-01").returns(items: [ raw ], next_cursor: nil)
        else
          client.expects(:get_cash_transactions_page).with(context.external.external_id, cursor: nil, start_date: "2020-01-01").returns(items: [ raw ], next_cursor: nil)
        end
        page = Provider::AccountData::Brex.new(client: client, timezone: context.family.timezone).fetch_transactions(
          account: { external_id: context.external.external_id, currency: "USD", metadata: { account_kind: kind } }, window: { start: "2020-01-01" })
        policy = Account::SourcePolicy.active.find_by!(account: context.account, resource: "transactions")
        batch = create_provider_batch(context.external.provider_connection, external_account: context.external,
          stream: "transactions", source_policy_version: policy.id, mode: page.mode, complete: page.complete?, payload: Ingestion::Codec.dump(page))
        context.external.provider_connection.with_lock do
          Ingestion::LedgerWriter.new(external_account: context.external, batch: batch).apply(Ingestion::Codec.load(batch.payload))
          batch.update!(status: "applied", applied_at: Time.current)
        end

        assert_equal 1, context.account.entries.count
        assert_equal original_ids, [ entry.reload.id, entry.entryable_id, observation.reload.id, posting.reload.id ]
        assert_equal financial, entry.attributes.except("updated_at")
        assert_equal transaction_state, entry.transaction.reload.attributes
        assert_equal original_proof, [ posting.reload.attributes, proof.reload.read_attribute_before_type_cast("payload") ]
      end
    end
  end

  test "empty cache uses its creation bound while only nonempty cache uses last success" do
    [ 3, 300 ].each do |age|
      with_history_source(created_at: age.days.ago) do |context|
        context.item.syncs.create!(status: "completed", completed_at: 250.days.ago)
        expected = [ context.source.created_at.getutc.to_date - 7.days, Time.current.getutc.to_date - 90.days ].max
        assert_equal expected, verify_history(context)
      end
    end
    recent = 10.days.ago.getutc.iso8601
    with_history_source(rows: [ transaction("initiated_at_date" => recent, "posted_at_date" => recent) ]) do |context|
      publish_identities(context)
      assert_equal Time.current.getutc.to_date - 90.days, verify_history(context)
      sync = context.item.syncs.create!(status: "completed", completed_at: 150.days.ago)
      assert_equal sync.completed_at.getutc.to_date - 7.days, verify_history(context)
    end
  end

  test "configured item floor is never widened by cached history or a last success" do
    with_history_source(rows: [ transaction ], item_start: Date.new(2024, 3, 4)) do |context|
      publish_identities(context)
      context.item.syncs.create!(status: "completed", completed_at: Time.utc(2018, 1, 1))
      assert_equal Date.new(2024, 3, 4), verify_history(context)
    end
  end

  test "an older cached account does not widen an empty sibling discovery account" do
    add_sibling = lambda do |item, _source, _account|
      raw = cash_snapshot("id" => "cash-sibling")
      sibling = item.brex_accounts.create!(account_id: raw.fetch("id"), name: "Sibling", currency: "USD", account_kind: "cash")
      sibling.upsert_brex_snapshot!(raw)
      payload = item.raw_payload.deep_dup
      payload.fetch("accounts") << raw
      payload.fetch("cash_accounts") << raw
      item.update!(raw_payload: payload)
    end
    with_history_source(rows: [ transaction ], before_copy: add_sibling) do |context|
      publish_identities(context)
      sibling = context.item.brex_accounts.where.not(id: context.source.id).sole
      external = context.control.provider_connection.external_accounts.find_by!(external_id: sibling.account_id)
      result = verify_result(context)
      assert_equal Date.new(2020, 1, 2), result.account_starts.fetch(context.external.id)
      assert_equal sibling.created_at.getutc.to_date - 7.days, result.account_starts.fetch(external.id)
    end
  end

  test "linked unfetched cache refuses but empty unlinked discovery remains explicit" do
    with_history_source(rows: nil) do |context|
      assert_raises(History::Conflict) { verify_history(context) }
    end
    with_history_source(rows: nil, linked: false) do |context|
      assert_equal context.source.created_at.getutc.to_date - 7.days, verify_history(context)
    end
    with_history_source(rows: [ transaction ], linked: false) do |context|
      assert_raises(History::Conflict) { verify_history(context) }
    end
  end

  test "cached rows without processed signed identity refuse even after completed sync" do
    with_history_source(rows: [ transaction ], import: false) do |context|
      publish_identities(context)
      context.item.syncs.create!(status: "completed", completed_at: Time.current)
      assert_raises(History::Conflict) { verify_history(context) }
      assert_empty context.account.entries
    end
  end

  test "changed cached economic notes and source metadata revisions are not mistaken for applied IDs" do
    changes = [ { "amount" => money(9999) }, { "description" => "Unapplied description" },
      { "expense_id" => "new-expense" }, { "card_id" => "changed-card" } ]
    changes.each do |change|
      mutation = ->(_item, source, _account) { source.update!(raw_transactions_payload: [ transaction(change) ]) }
      with_history_source(rows: [ transaction ], before_copy: mutation) do |context|
        publish_identities(context)
        before = retained_state(context)
        assert_raises(History::Conflict) { verify_history(context) }
        assert_equal before, retained_state(context)
      end
    end
  end

  test "accounting classification changes do not replace the original source semantics" do
    mutation = ->(_item, _source, account) { account.entries.sole.transaction.update!(kind: "funds_movement") }
    with_history_source(rows: [ transaction ], before_copy: mutation) do |context|
      publish_identities(context)
      assert_equal Date.new(2020, 1, 2), verify_history(context)
      assert_equal "funds_movement", context.account.entries.sole.transaction.kind
    end
  end

  test "duplicate malformed fractional-money and foreign cash rows refuse" do
    samples = [ [ transaction, transaction ], [ nil ], [ transaction("amount" => money("123.4")) ],
      [ transaction("account_id" => "other-cash") ], [ transaction("posted_at_date" => "not-a-date") ],
      [ transaction("amount" => { "amount" => 100, "currency" => "UNKNOWN" }) ], [ transaction("amount" => 100) ] ]
    samples.each do |rows|
      with_history_source(rows: rows, import: false) do |context|
        assert_raises(History::Conflict) { verify_history(context) }
        assert_empty context.account.entries
      end
    end
  end

  test "missing inventory collections and omitted source accounts refuse" do
    [ :missing_collection, :omitted_account, :unapplied_account ].each do |change|
      mutation = lambda do |item, _source, _account|
        payload = item.raw_payload.deep_dup
        case change
        when :missing_collection then payload.delete("cash_accounts")
        when :omitted_account
          payload["accounts"] = []
          payload["cash_accounts"] = []
        when :unapplied_account
          raw = cash_snapshot("id" => "not-imported")
          payload["accounts"] << raw
          payload["cash_accounts"] << raw
        end
        item.update!(raw_payload: payload)
      end
      with_history_source(before_copy: mutation) do |context|
        assert_raises(History::Conflict) { verify_history(context) }
      end
    end
  end

  test "company card count totals and physical identity substitutions refuse" do
    [ :count, :balance, :physical_identity, :currency ].each do |change|
      mutation = lambda do |item, source, _account|
        payload = item.raw_payload.deep_dup
        aggregate = payload.fetch("accounts").sole
        case change
        when :count then aggregate["card_accounts_count"] = 1
        when :balance then aggregate["current_balance"] = money(1)
        when :physical_identity then aggregate["id"] = "physical-card-1"
        when :currency
          payload["card_accounts"].last["current_balance"]["currency"] = "EUR"
          aggregate["raw_card_accounts"] = payload["card_accounts"].deep_dup
        end
        source.upsert_brex_snapshot!(aggregate)
        item.update!(raw_payload: payload)
      end
      with_history_source(kind: "card", before_copy: mutation) do |context|
        assert_raises(History::Conflict) { verify_history(context) }
      end
    end
  end

  test "signed identity no longer live or with changed pending identity refuses" do
    [ :entry_source, :pending, :source ].each do |change|
      with_history_source(rows: [ transaction ]) do |context|
        publish_identities(context)
        entry = context.account.entries.sole
        case change
        when :entry_source then EntrySource.where(entry_id: entry.id).delete_all
        when :pending then entry.transaction.update!(extra: entry.transaction.extra.merge("brex" => { "pending" => true }))
        when :source then entry.update!(source: "manual")
        end
        assert_raises(History::Conflict) { verify_history(context) }
      end
    end
  end

  test "post-copy source cache inventory and configured-start drift refuse" do
    [ :cache, :inventory, :start ].each do |change|
      with_history_source do |context|
        case change
        when :cache then context.source.update!(raw_transactions_payload: [ transaction ])
        when :inventory then context.item.update!(raw_payload: {})
        when :start then context.item.update!(sync_start_date: 100.days.ago)
        end
        assert_raises(History::Conflict) { verify_history(context) }
      end
    end
  end

  test "final transaction exclusive permit and exact family are required" do
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

  test "row and byte budgets fail before any mutation" do
    with_history_source(rows: [ transaction ]) do |context|
      before = retained_state(context)
      %i[MAX_ACCOUNTS MAX_RECORDS MAX_BYTES].each do |constant|
        with_history_limit(constant, 0) { assert_raises(History::Conflict) { verify_history(context) } }
      end
      assert_equal before, retained_state(context)
    end
  end

  private
    def money(amount)
      { "amount" => amount, "currency" => "USD" }
    end

    def cash_snapshot(changes = {})
      { "id" => "cash-remote", "name" => "Brex Cash", "account_kind" => "cash", "status" => "ACTIVE",
        "current_balance" => money(10_000), "available_balance" => money(8_000) }.merge(changes)
    end

    def card_inventory
      cards = [ 1, 2 ].map do |number|
        { "id" => "physical-card-#{number}", "account_kind" => "card", "status" => "ACTIVE",
          "current_balance" => money(5_000 * number), "available_balance" => money(50_000 - 5_000 * number),
          "account_limit" => money(50_000) }
      end
      aggregate = { "id" => "card_primary", "name" => "Brex Card", "account_kind" => "card", "status" => "ACTIVE",
        "current_balance" => money(15_000), "available_balance" => money(85_000), "account_limit" => money(100_000),
        "card_accounts_count" => 2, "raw_card_accounts" => cards.deep_dup }
      { "accounts" => [ aggregate ], "cash_accounts" => [], "card_accounts" => cards }
    end

    def transaction(changes = {})
      { "id" => "retained-transaction", "account_id" => "cash-remote", "amount" => money(1234),
        "description" => "Retained purchase", "type" => "PURCHASE", "expense_id" => "original-expense",
        "initiated_at_date" => "2020-01-02T12:00:00Z", "posted_at_date" => "2020-01-03T12:00:00Z" }.merge(changes)
    end

    def with_history_source(rows: [], kind: "cash", created_at: Time.current, item_start: nil, linked: true, import: true, before_copy: nil)
      with_provider_encryption do
        family = families(:dylan_family)
        timestamps = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
        item = BrexItem.create!(family: family, name: "Brex cutover", token: "private-test-token", sync_start_date: item_start)
        account = family.accounts.create!(name: "Retained Brex", currency: "USD", balance: 100,
          accountable: kind == "card" ? CreditCard.new : Depository.new)
        begin
          payload = kind == "card" ? card_inventory : { "accounts" => [ cash_snapshot ], "cash_accounts" => [ cash_snapshot ], "card_accounts" => [] }
          item.upsert_brex_snapshot!(payload)
          snapshot = payload.fetch("accounts").sole
          source = item.brex_accounts.create!(account_id: snapshot.fetch("id"), name: "Brex source", currency: "USD",
            account_kind: kind, raw_transactions_payload: rows, created_at: created_at)
          source.upsert_brex_snapshot!(snapshot)
          link = AccountProvider.create!(account: account, provider: source) if linked
          Array(rows).each { |raw| BrexEntry::Processor.new(raw, brex_account: source).process } if import && linked
          before_copy&.call(item, source, account)
          copier = Provider::AccountData::MigrationCopier.new(provider_key: "brex", legacy_item_id: item.id, batch_size: 1)
          control = nil
          20.times do
            control = copier.run_quiesced.reload
            break if control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", control.high_water_mark["phase"]
          external = control.provider_connection.external_accounts.find_by!(external_id: source.reload.account_id)
          mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
          Account::SourcePolicy.select!(account: account, account_provider: link.reload, resource: "transactions") if link
          yield IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: source, account: account,
            link: link, copier: copier, control: control, mapping: mapping, external: external)
        ensure
          Sync.where(syncable_type: "BrexItem", syncable_id: item.id).delete_all
          cleanup_identity_source(item, account)
          Family.where(id: family.id).update_all(timestamps)
        end
      end
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
