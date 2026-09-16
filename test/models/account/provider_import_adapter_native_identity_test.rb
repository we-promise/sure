require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Account::ProviderImportAdapterNativeIdentityTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "native import cannot accept an arbitrary Entry as a reviewed identity" do
    entry = manual_entry
    before = entry.attributes
    assert_raises(Ingestion::MappedEntryResolver::Conflict) do
      import(native_identity: true, resolved_entry: entry)
    end
    assert_equal before, entry.reload.attributes
  end

  test "a resolved identity cannot be supplied to an ordinary legacy call" do
    assert_raises(ArgumentError) { import(resolved_entry: manual_entry) }
  end

  test "a stale typed resolution is revalidated inside the importer before financial changes" do
    with_provider_encryption do
      entry, external, observation = mapped_entry
      resolution = Ingestion::MappedEntryResolver.new(external_account: external, account: accounts(:depository), definition: Provider::AccountData::Plaid.definition)
        .resolve(source_record: observation, kind: "transaction", external_id: "incoming", entryable_type: "Transaction")
      before = entry.attributes
      observation.entry_source.destroy!

      assert_raises(Ingestion::MappedEntryResolver::Conflict) { import(native_identity: true, resolved_entry: resolution) }

      assert_equal before, entry.reload.attributes
    end
  end

  test "a typed resolution for one provider ID cannot authorize another import" do
    with_provider_encryption do
      entry, external, observation = mapped_entry
      resolution = Ingestion::MappedEntryResolver.new(external_account: external, account: accounts(:depository), definition: Provider::AccountData::Plaid.definition)
        .resolve(source_record: observation, kind: "transaction", external_id: "incoming", entryable_type: "Transaction")
      before = entry.attributes
      assert_raises(Ingestion::MappedEntryResolver::Conflict) { import(external_id: "different", native_identity: true, resolved_entry: resolution) }
      assert_equal before, entry.reload.attributes
    end
  end

  test "direct native Trade import respects protection without relying on the outer LedgerWriter" do
    entry = entries(:trade)
    entry.update!(source: "plaid", external_id: "trade", excluded: true)
    before = [ entry.reload.attributes, entry.trade.reload.attributes ]
    adapter = Account::ProviderImportAdapter.new(entry.account)

    result = adapter.import_trade(external_id: "trade", source: "plaid", native_identity: true, security: securities(:aapl),
      quantity: BigDecimal("7"), price: BigDecimal("1"), amount: BigDecimal("7"), currency: "USD", date: Date.current, name: "Changed")

    assert_equal entry.id, result.id
    assert_equal before, [ entry.reload.attributes, entry.trade.reload.attributes ]
    assert_equal "excluded", adapter.skipped_entries.sole.fetch(:reason)
  end

  test "native identity lookup checks type before a protected Entry can be skipped" do
    entry = entries(:trade)
    entry.update!(source: "plaid", external_id: "incoming", user_modified: true)
    before = [ entry.reload.attributes, entry.trade.reload.attributes ]
    assert_raises(ArgumentError) do
      Account::ProviderImportAdapter.new(entry.account).import_transaction(external_id: "incoming", source: "plaid", native_identity: true,
        amount: BigDecimal("8"), currency: "USD", date: Date.current, name: "Wrong type")
    end
    assert_equal before, [ entry.reload.attributes, entry.trade.reload.attributes ]
  end

  test "legacy calls retain their prior manual claiming behavior" do
    entry = manual_entry(plaid_id: "legacy-unscoped", import_locked: true)
    assert_no_difference "Entry.count" do
      assert_equal entry.id, import.id
    end
    assert_equal "incoming", entry.reload.external_id
    assert_equal "plaid", entry.source
    assert_equal "Original", entry.name
    assert entry.import_locked?
  end

  test "native mode does not infer a pending transition from equal amount and date" do
    with_provider_encryption do
      entry = manual_entry(source: "plaid", external_id: "pending")
      entry.transaction.update!(extra: { "plaid" => { "pending" => true } })
      assert_difference "Entry.count", 1 do
        assert_not_equal entry.id, import(native_identity: true).id
      end
      assert_equal "pending", entry.reload.external_id
      assert entry.transaction.pending?
    end
  end

  private
    def manual_entry(**attributes)
      accounts(:depository).entries.create!({ name: "Original", date: Date.current, amount: 83, currency: "USD", entryable: Transaction.new }.merge(attributes))
    end

    def import(**attributes)
      Account::ProviderImportAdapter.new(accounts(:depository)).import_transaction(**{
        external_id: "incoming", source: "plaid", amount: BigDecimal("83"), currency: "USD", date: Date.current, name: "Incoming"
      }.merge(attributes))
    end

    def mapped_entry
      connection = create_provider_connection(provider_key: "plaid")
      external = create_external_account(connection)
      AccountProvider.create!(account: accounts(:depository), external_account: external)
      entry = manual_entry(source: "plaid", external_id: "incoming")
      record = Ingestion::Record.transaction(external_id: "incoming", name: "Incoming", date: Date.current, amount: BigDecimal("83"), currency: "USD", pending: false)
      batch = create_provider_batch(connection, external_account: external, stream: "transactions",
        payload: Ingestion::Codec.dump(Provider::AccountData::Page.new(records: [ record ], complete: true)))
      observation = SourceRecord.create!(external_account: external, account: accounts(:depository), family: families(:dylan_family),
        ingestion_batch: batch, kind: "transaction", external_id: "incoming")
      observation.create_entry_source!(entry: entry, account: accounts(:depository), family: families(:dylan_family), role: "posting", match_method: "reviewed")
      [ entry, external, observation ]
    end
end
