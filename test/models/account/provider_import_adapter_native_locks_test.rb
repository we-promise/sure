require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Account::ProviderImportAdapterNativeLocksTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "a duplicate is reloaded under lock before newly added protection is checked" do
    entry = cash_entry
    stale = Entry.find(entry.id)
    entry.update!(user_modified: true, name: "Keep the edit")
    adapter = Account::ProviderImportAdapter.new(entry.account)
    adapter.expects(:find_duplicate_transaction).with(date: Date.current, amount: BigDecimal("83"), currency: "USD", unclaimed_only: true).returns(stale)

    assert_no_difference "Entry.count" do
      assert_equal entry.id, cash_import(adapter: adapter).id
    end

    assert_equal "Keep the edit", entry.reload.name
    assert entry.user_modified?
    assert_equal "incoming", entry.external_id
    assert_equal "user_modified", adapter.skipped_entries.sole[:reason]
  end

  test "a duplicate claimed by a legacy provider after selection cannot be stolen" do
    entry = cash_entry
    stale = Entry.find(entry.id)
    entry.update!(external_id: "other-provider", source: "up")
    before = [ entry.attributes, entry.transaction.attributes ]
    adapter = Account::ProviderImportAdapter.new(entry.account)
    adapter.expects(:find_duplicate_transaction).returns(stale)

    assert_no_difference "Entry.count" do
      assert_raises(Ingestion::MappedEntryResolver::Conflict) { cash_import(adapter: adapter) }
    end
    assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
  end

  test "a duplicate whose financial identity changed after selection is not adopted" do
    entry = cash_entry
    stale = Entry.find(entry.id)
    entry.update!(amount: "84", date: Date.current - 1)
    adapter = Account::ProviderImportAdapter.new(entry.account)
    adapter.expects(:find_duplicate_transaction).returns(stale)

    assert_raises(Ingestion::MappedEntryResolver::Conflict) { cash_import(adapter: adapter) }
    assert_nil entry.reload.external_id
    assert_nil entry.source
    assert_equal BigDecimal("84"), entry.amount
  end

  test "a newly reviewed provider mapping also disqualifies a stale manual duplicate" do
    with_provider_encryption do
      entry = cash_entry
      stale = Entry.find(entry.id)
      mapping_for(entry)
      adapter = Account::ProviderImportAdapter.new(entry.account)
      adapter.expects(:find_duplicate_transaction).returns(stale)

      assert_raises(Ingestion::MappedEntryResolver::Conflict) { cash_import(adapter: adapter) }
      assert_nil entry.reload.external_id
      assert_nil entry.source
    end
  end

  test "native cash refresh preserves reconciliation even without other protection flags" do
    entry = cash_entry(source: "plaid", external_id: "incoming")
    entry.mark_reconciled!
    entry.transaction.update!(extra: { "plaid" => { "pending" => true } })

    # Reconciliation also wins over the legacy user_modified pending-clear
    # exception when both protections are present.
    [ false, true ].each do |user_modified|
      entry.update!(user_modified: user_modified)
      before = [ entry.reload.attributes, entry.transaction.reload.attributes ]
      adapter = Account::ProviderImportAdapter.new(entry.account)
      assert_equal entry.id, cash_import(adapter: adapter, amount: BigDecimal("84"), extra: { "plaid" => { "pending" => false } }).id
      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
      assert_equal "reconciled", adapter.skipped_entries.sole[:reason]
    end
  end

  test "a newly reconciled manual duplicate adopts only the provider identity" do
    entry = cash_entry
    stale = Entry.find(entry.id)
    entry.mark_reconciled!
    before = [ entry.attributes.except("external_id", "source", "updated_at"), entry.transaction.attributes ]
    adapter = Account::ProviderImportAdapter.new(entry.account)
    adapter.expects(:find_duplicate_transaction).returns(stale)

    assert_no_difference "Entry.count" do
      assert_equal entry.id, cash_import(adapter: adapter, extra: { "plaid" => { "new_data" => true } }).id
    end
    assert_equal before, [ entry.reload.attributes.except("external_id", "source", "updated_at"), entry.transaction.reload.attributes ]
    assert_equal "incoming", entry.external_id
    assert_equal "plaid", entry.source
    assert_equal "reconciled", adapter.skipped_entries.sole[:reason]
  end

  test "native cash changes to locked amount currency or date reject the complete record" do
    entry = cash_entry(source: "plaid", external_id: "incoming")
    { "amount" => { amount: BigDecimal("84") }, "currency" => { currency: "EUR" }, "date" => { date: Date.current - 1 } }.each do |attribute, change|
      entry.update!(locked_attributes: { attribute => Time.current.iso8601 })
      before = [ entry.attributes, entry.transaction.reload.attributes ]
      assert_raises(Ingestion::MappedEntryResolver::Conflict) do
        cash_import(**change, extra: { "plaid" => { "pending" => false, "new_data" => true } })
      end
      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
    end
  end

  test "the same lock rule applies to a reviewed mapped UUID without user_modified" do
    with_provider_encryption do
      entry = cash_entry(plaid_id: "incoming", locked_attributes: { "amount" => Time.current.iso8601 })
      external, observation = mapping_for(entry, match_method: "legacy_plaid_id")
      resolved = Ingestion::MappedEntryResolver.new(external_account: external, account: entry.account, definition: Provider::AccountData::Plaid.definition)
        .resolve(source_record: observation, kind: "transaction", external_id: "incoming", entryable_type: "Transaction")

      assert_raises(Ingestion::MappedEntryResolver::Conflict) { cash_import(amount: BigDecimal("84"), resolved_entry: resolved) }
      assert_equal BigDecimal("83"), entry.reload.amount
      assert_nil entry.external_id
      assert_nil entry.source
      assert_not entry.user_modified?
    end
  end

  test "a pending promotion with a locked economic conflict changes neither UUID identity nor metadata" do
    with_provider_encryption do
      entry = cash_entry(source: "plaid", external_id: "incoming", locked_attributes: { "amount" => true })
      entry.transaction.update!(extra: { "plaid" => { "pending" => true } })
      external, observation = mapping_for(entry, pending: true)
      resolved = Ingestion::MappedEntryResolver.new(external_account: external, account: entry.account, definition: Provider::AccountData::Plaid.definition)
        .resolve_pending_transition(source_record: observation, pending_external_id: "incoming", posted_external_id: "posted")
      before = [ entry.reload.attributes, entry.transaction.reload.attributes ]

      assert_raises(Ingestion::MappedEntryResolver::Conflict) do
        cash_import(external_id: "posted", amount: BigDecimal("84"), pending_transaction_id: "incoming", resolved_entry: resolved)
      end

      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
      assert_equal entry.id, observation.entry_source.entry_id
    end
  end

  test "unchanged locked economic values accept equivalent typed input and descriptive updates" do
    entry = cash_entry(source: "plaid", external_id: "incoming", locked_attributes: { "amount" => true, "currency" => true, "date" => true })
    result = cash_import(date: Date.current.iso8601)
    assert_equal entry.id, result.id
    assert_equal "Incoming", entry.reload.name
    assert_equal BigDecimal("83"), entry.amount
  end

  test "native cash classification respects explicitly cleared or selected field locks" do
    entry = cash_entry(source: "plaid", external_id: "incoming")
    entry.transaction.update!(kind: "standard", investment_activity_label: nil, category_id: nil,
      locked_attributes: { "kind" => true, "investment_activity_label" => true, "category_id" => true })
    cash_import(kind: "funds_movement", investment_activity_label: "Contribution")
    assert_equal "standard", entry.transaction.reload.kind
    assert_nil entry.transaction.investment_activity_label
    assert_nil entry.transaction.category_id
  end

  test "a locked whole metadata field rejects the complete native financial update" do
    entry = cash_entry(source: "plaid", external_id: "incoming")
    entry.transaction.update!(extra: { "exchange_rate" => 1.25 }, locked_attributes: { "extra" => true })
    before = [ entry.reload.attributes, entry.transaction.reload.attributes ]

    assert_raises(Ingestion::MappedEntryResolver::Conflict) do
      cash_import(amount: BigDecimal("84"), extra: { "plaid" => { "mcc" => "5812" } })
    end

    assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
  end

  test "an unchanged locked metadata projection still allows unlocked financial and descriptive edits" do
    entry = cash_entry(source: "plaid", external_id: "incoming")
    metadata = { "plaid" => { "pending" => false, "mcc" => "5812" }, "exchange_rate" => 1.25 }
    entry.transaction.update!(extra: metadata, locked_attributes: { "extra" => true })

    cash_import(amount: BigDecimal("84"), extra: metadata.deep_dup)

    assert_equal BigDecimal("84"), entry.reload.amount
    assert_equal "Incoming", entry.name
    assert_equal metadata, entry.transaction.reload.extra
  end

  test "pending clearing with no incoming metadata cannot bypass a whole metadata lock" do
    entry = cash_entry(source: "plaid", external_id: "incoming")
    entry.transaction.update!(extra: { "plaid" => { "pending" => true } }, locked_attributes: { "extra" => true })
    [ false, true ].each do |user_modified|
      entry.update!(user_modified: user_modified)
      before = [ entry.reload.attributes, entry.transaction.reload.attributes ]

      assert_raises(Ingestion::MappedEntryResolver::Conflict) { cash_import }

      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
    end
  end

  test "protected observations which skip metadata remain skips even when extra is locked" do
    entry = cash_entry(source: "plaid", external_id: "incoming")
    entry.transaction.update!(extra: { "exchange_rate" => 1.25 }, locked_attributes: { "extra" => true })
    [ { excluded: true }, { import_locked: true }, { user_modified: true }, { reconciled_at: Time.current } ].each do |protection|
      entry.update!({ excluded: false, import_locked: false, user_modified: false, reconciled_at: nil }.merge(protection))
      before = [ entry.reload.attributes, entry.transaction.reload.attributes ]

      assert_equal entry.id, cash_import(amount: BigDecimal("84"), extra: { "plaid" => { "mcc" => "5812" } }).id

      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
    end
  end

  test "a locked metadata conflict rejects a pending identity promotion before aliases or identity change" do
    with_provider_encryption do
      entry = cash_entry(source: "plaid", external_id: "incoming")
      entry.transaction.update!(extra: { "plaid" => { "pending" => true } }, locked_attributes: { "extra" => true })
      external, observation = mapping_for(entry, pending: true)
      resolved = Ingestion::MappedEntryResolver.new(external_account: external, account: entry.account, definition: Provider::AccountData::Plaid.definition)
        .resolve_pending_transition(source_record: observation, pending_external_id: "incoming", posted_external_id: "posted")
      before = [ entry.reload.attributes, entry.transaction.reload.attributes ]

      assert_raises(Ingestion::MappedEntryResolver::Conflict) do
        cash_import(external_id: "posted", pending_transaction_id: "incoming", resolved_entry: resolved)
      end

      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
      assert_equal entry.id, observation.entry_source.entry_id
    end
  end

  test "manual adoption with a locked metadata conflict leaves the identity unclaimed" do
    entry = cash_entry
    entry.transaction.update!(extra: { "exchange_rate" => 1.25 }, locked_attributes: { "extra" => true })
    before = [ entry.reload.attributes, entry.transaction.reload.attributes ]

    assert_no_difference "Entry.count" do
      assert_raises(Ingestion::MappedEntryResolver::Conflict) { cash_import(extra: { "plaid" => { "pending" => false } }) }
    end

    assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
  end

  test "a virtual cash exchange rate lock is checked against the projected metadata" do
    entry = cash_entry(source: "plaid", external_id: "incoming")
    entry.transaction.update!(extra: { "exchange_rate" => 1.25 }, locked_attributes: { "exchange_rate" => true })

    assert_raises(Ingestion::MappedEntryResolver::Conflict) { cash_import(extra: { "exchange_rate" => 1.5 }) }
    assert_equal 1.25, entry.transaction.reload.exchange_rate
  end

  test "legacy metadata merging retains its existing behavior for locked JSON" do
    entry = cash_entry(source: "plaid", external_id: "incoming")
    entry.transaction.update!(extra: { "plaid" => { "pending" => true } }, locked_attributes: { "extra" => true })

    cash_import(native_identity: false, extra: { "plaid" => { "pending" => false, "mcc" => "5812" } })

    assert_equal({ "plaid" => { "pending" => false, "mcc" => "5812" } }, entry.transaction.reload.extra)
  end

  test "native Trade economic locks reject rather than combining incompatible locked and provider values" do
    entry = trade_entry
    variants = [
      [ entry, "amount", { amount: BigDecimal("22") } ],
      [ entry, "date", { date: Date.current - 1 } ],
      [ entry, "currency", { currency: "EUR" } ],
      [ entry.trade, "qty", { quantity: BigDecimal("3"), amount: BigDecimal("31") } ],
      [ entry.trade, "price", { price: BigDecimal("11"), amount: BigDecimal("23") } ],
      [ entry.trade, "fee", { fee: BigDecimal("2"), amount: BigDecimal("22") } ],
      [ entry.trade, "currency", { currency: "EUR" } ],
      [ entry.trade, "security_id", { security: securities(:msft) } ],
      [ entry.trade, "investment_activity_label", { activity_label: "Transfer" } ],
      [ entry.trade, "extra", { exchange_rate: BigDecimal("1.5") } ],
      [ entry.trade, "exchange_rate", { exchange_rate: BigDecimal("1.5") } ]
    ]
    variants.each do |model, attribute, change|
      entry.update!(locked_attributes: {})
      entry.trade.update!(locked_attributes: {})
      model.update!(locked_attributes: { attribute => Time.current.iso8601 })
      before = [ entry.reload.attributes, entry.trade.reload.attributes ]
      assert_raises(Ingestion::MappedEntryResolver::Conflict) { trade_import(entry, **change) }
      assert_equal before, [ entry.reload.attributes, entry.trade.reload.attributes ]
    end
  end

  test "locked Trade descriptions remain unchanged while a complete unlocked economic tuple updates" do
    entry = trade_entry
    entry.update!(locked_attributes: { "name" => true, "notes" => true })
    trade_import(entry, quantity: BigDecimal("3"), price: BigDecimal("11"), amount: BigDecimal("34"), name: "Changed", notes: "Changed notes")
    assert_equal "Personal trade", entry.reload.name
    assert_equal "Personal notes", entry.notes
    assert_equal BigDecimal("34"), entry.amount
    assert_equal BigDecimal("3"), entry.trade.reload.qty
    assert_equal BigDecimal("11"), entry.trade.price
  end

  test "native Trade refresh preserves a reconciled financial tuple and metadata" do
    entry = trade_entry
    entry.mark_reconciled!
    before = [ entry.attributes, entry.trade.attributes ]
    assert_not entry.protected_from_sync?

    assert_equal entry.id, trade_import(entry, quantity: BigDecimal("3"), price: BigDecimal("11"), amount: BigDecimal("34"),
      name: "Changed", notes: "Changed notes", extra: { "provider_metadata" => true }).id

    assert_equal before, [ entry.reload.attributes, entry.trade.reload.attributes ]
  end

  test "legacy importer calls retain the existing direct economic update semantics" do
    entry = cash_entry(source: "plaid", external_id: "incoming", locked_attributes: { "amount" => true })
    entry.mark_reconciled!
    cash_import(amount: BigDecimal("84"), native_identity: false)
    assert_equal BigDecimal("84"), entry.reload.amount
    trade = trade_entry
    trade.mark_reconciled!
    trade.trade.update!(locked_attributes: { "qty" => true })
    trade_import(trade, quantity: BigDecimal("3"), amount: BigDecimal("31"), native_identity: false)
    assert_equal BigDecimal("3"), trade.trade.reload.qty
  end

  private
    def cash_entry(**attributes)
      accounts(:depository).entries.create!({ name: "Original", date: Date.current, amount: BigDecimal("83"), currency: "USD",
        entryable: Transaction.new }.merge(attributes))
    end

    def cash_import(adapter: Account::ProviderImportAdapter.new(accounts(:depository)), **attributes)
      adapter.import_transaction(**{ external_id: "incoming", source: "plaid", amount: BigDecimal("83"), currency: "USD", date: Date.current,
        name: "Incoming", native_identity: true }.merge(attributes))
    end

    def trade_entry
      accounts(:investment).entries.create!(name: "Personal trade", notes: "Personal notes", date: Date.current, amount: BigDecimal("21"),
        currency: "USD", source: "plaid", external_id: "locked-trade", entryable: Trade.new(security: securities(:aapl), qty: BigDecimal("2"),
          price: BigDecimal("10"), fee: BigDecimal("1"), currency: "USD", investment_activity_label: "Buy"))
    end

    def trade_import(entry, **attributes)
      Account::ProviderImportAdapter.new(entry.account).import_trade(**{ external_id: entry.external_id, source: "plaid", native_identity: true,
        security: securities(:aapl), quantity: BigDecimal("2"), price: BigDecimal("10"), fee: BigDecimal("1"), amount: BigDecimal("21"),
        currency: "USD", date: Date.current, name: "Provider trade", activity_label: "Buy" }.merge(attributes))
    end

    def mapping_for(entry, match_method: "reviewed", pending: false)
      connection = create_provider_connection(provider_key: "plaid", family: entry.account.family)
      external = create_external_account(connection)
      AccountProvider.create!(account: entry.account, external_account: external)
      record = Ingestion::Record.transaction(external_id: "incoming", name: "Source", date: Date.current, amount: BigDecimal("83"), currency: "USD", pending: pending)
      batch = create_provider_batch(connection, external_account: external, stream: "transactions",
        payload: Ingestion::Codec.dump(Provider::AccountData::Page.new(records: [ record ], complete: true)))
      observation = SourceRecord.create!(external_account: external, account: entry.account, family: entry.account.family,
        ingestion_batch: batch, kind: "transaction", external_id: "incoming", pending: pending)
      observation.create_entry_source!(entry: entry, account: entry.account, family: entry.account.family, role: "posting", match_method: match_method)
      [ external, observation ]
    end
end
