require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::CoinstatsMigrationTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "copy stores encrypted reviewed routing and leaves monetary history links and raw typed rows intact" do
    with_provider_encryption do
      item = CoinstatsItem.create!(family: families(:dylan_family), name: "Wallet", api_key: "private-api-key")
      raw = { "source" => "wallet", "address" => "0xPrivateABC", "blockchain" => "ethereum", "symbol" => "ETH",
        "amount" => "0.000000000000000123", "price" => "3210.123456789123456789", "private_owner" => "private-owner" }
      source = item.coinstats_accounts.create!(account_id: "ethereum", wallet_address: "0xPrivateABC", name: "Ethereum", currency: "USD",
        current_balance: BigDecimal("123.4567"), raw_payload: raw, raw_transactions_payload: [ { "hash" => { "id" => "old-event" } } ])
      financial = accounts(:depository)
      link = AccountProvider.create!(account: financial, provider: source)
      before = financial.attributes
      entry_ids = financial.entries.pluck(:id)
      copier = copy(item)
      mapping = copier.control.provider_migration_mappings.find_by!(legacy_id: source.id, role: "external_account")
      external = mapping.target.reload
      descriptor = external.sensitive_details.fetch("source_descriptor")

      assert_equal "shadow", copier.control.state
      assert copier.control.provider_connection.disabled?
      assert_equal JSON.generate([ [ "account_id", "ethereum" ], [ "wallet_address", "0xPrivateABC" ] ]), external.external_id
      assert_equal "wallet", descriptor.fetch("source")
      assert_equal "0xPrivateABC", descriptor.fetch("address")
      assert_equal source.id, descriptor.fetch("legacy_account_uuid")
      assert_equal [], descriptor.keys & %w[amount balance price api_key private_owner]
      assert_provider_column_encrypted(external, :sensitive_details, "0xPrivateABC")
      assert_equal BigDecimal("123.4567"), external.current_balance
      assert_equal link.id, external.account_provider.id
      assert_equal "CoinstatsAccount", link.reload.provider_type
      assert_equal source.id, link.provider_id
      assert_equal before, financial.reload.attributes
      assert_equal entry_ids, financial.entries.pluck(:id)
      archived = copier.snapshot_for(mapping).fetch("attributes")
      assert_equal raw, archived.fetch("raw_payload")
      assert_equal source.raw_transactions_payload, archived.fetch("raw_transactions_payload")
      assert mapping.verified_at.present?
    end
  end

  test "descriptor verification detects a modified routing projection" do
    with_provider_encryption do
      item = CoinstatsItem.create!(family: families(:dylan_family), name: "Exchange", api_key: "key")
      source = item.coinstats_accounts.create!(account_id: "portfolio:one", wallet_address: nil, name: "Exchange", currency: "USD", current_balance: 10,
        raw_payload: { "source" => "exchange", "portfolio_id" => "one", "portfolio_account" => true, "coins" => [], "exchange_name" => "Example" })
      copier = Provider::AccountData::MigrationCopier.new(provider_key: "coinstats", legacy_item_id: item.id)
      copier.run
      mapping = copier.control.provider_migration_mappings.find_by!(legacy_id: source.id, role: "external_account")
      external = mapping.target
      details = external.sensitive_details.deep_dup
      assert_equal "one", details.dig("source_descriptor", "portfolio_id")
      assert_equal true, details.dig("source_descriptor", "portfolio_account")
      assert_equal JSON.generate([ [ "account_id", "portfolio:one" ], [ "wallet_address", nil ] ]), external.external_id
      details["source_descriptor"]["portfolio_id"] = "other"
      external.update!(sensitive_details: details)

      assert_raises(Provider::AccountData::MigrationCopier::Conflict) { copier.run }
      assert_nil mapping.reload.verified_at
      assert copier.control.reload.failed?
    end
  end

  test "ambiguous routing aborts copying before a new account link is assigned" do
    with_provider_encryption do
      item = CoinstatsItem.create!(family: families(:dylan_family), name: "Ambiguous", api_key: "key")
      source = item.coinstats_accounts.create!(account_id: "ethereum", wallet_address: "0xABC", name: "Wallet", currency: "USD",
        raw_payload: { "source" => "wallet", "address" => "0xABC", "blockchain" => "ethereum", "portfolio_id" => "another-source" })
      link = AccountProvider.create!(account: accounts(:depository), provider: source)
      copier = Provider::AccountData::MigrationCopier.new(provider_key: "coinstats", legacy_item_id: item.id)
      assert_raises(Provider::AccountData::MigrationManifest::InvalidSource) { copier.run }
      assert_nil link.reload.external_account_id
      assert_equal source.id, link.provider_id
      assert copier.control.provider_connection.disabled?
    end
  end

  test "new trade evidence cannot destroy or replace an existing CoinStats Transaction UUID" do
    with_provider_encryption do
      Provider::AccountData::Registry.stubs(:fetch).with("coinstats").returns(Provider::AccountData::Coinstats)
      connection = create_provider_connection(provider_key: "coinstats", credentials: { "api_key" => "key" })
      external = create_external_account(connection)
      financial = accounts(:investment)
      link = AccountProvider.create!(account: financial, external_account: external)
      policy = Account::SourcePolicy.select!(account: financial, account_provider: link, resource: "activities")
      entry = financial.entries.create!(entryable: Transaction.new, name: "Reviewed legacy trade", date: Date.current,
        amount: 100, currency: "USD", source: "coinstats", external_id: "coinstats_trade-1", user_modified: true)
      transaction_id = entry.entryable_id
      record = Ingestion::Record.activity(external_id: entry.external_id, name: "Buy ETH", currency: "USD", date: Date.current,
        amount: BigDecimal("100"), quantity: BigDecimal("1"), price: BigDecimal("100"), activity_type: "buy",
        security: { ticker: "CRYPTO:ETH" }, metadata: { update_policy: "insert_only" })
      page = Provider::AccountData::Page.new(records: [ record ], complete: true)
      batch = create_provider_batch(connection, external_account: external, stream: "activities", payload: Ingestion::Codec.dump(page), source_policy_version: policy.id)
      writer = Ingestion::LedgerWriter.new(external_account: external, batch: batch, securities: { [ "activity", entry.external_id ] => securities(:aapl) })

      assert_no_difference [ "Entry.count", "Transaction.count", "Trade.count", "SourceRecord.count" ] do
        assert_raises(Provider::AccountData::InvalidResponse) do
          IngestionBatch.transaction(requires_new: true) { writer.apply(page) }
        end
      end
      assert_equal "Reviewed legacy trade", entry.reload.name
      assert_equal transaction_id, entry.entryable_id
      assert entry.transaction?
      assert entry.user_modified?
    end
  end

  private
    def copy(item)
      copier = Provider::AccountData::MigrationCopier.new(provider_key: "coinstats", legacy_item_id: item.id)
      10.times do
        copier.run
        return copier if copier.control.reload.shadow?
      end
      flunk "Expected bounded copy to reach shadow"
    end
end
