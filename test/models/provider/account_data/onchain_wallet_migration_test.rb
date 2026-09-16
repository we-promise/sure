require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::OnchainWalletMigrationTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "copy preserves financial UUIDs legacy movement namespace selected assets and encrypted routing" do
    with_provider_encryption do
      item = OnchainWalletItem.create!(family: families(:dylan_family), name: "Cold wallets", etherscan_api_key: "private-explorer-key")
      source = item.onchain_wallet_accounts.create!(chain: "bitcoin", wallet_address: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT", asset_kind: "native",
        symbol: "BTC", name: "Bitcoin", currency: "USD", decimals: 8, quantity: BigDecimal("0.125"), current_balance: BigDecimal("6000"),
        raw_movements_payload: { "movements" => [ { "external_id" => "tx", "amount" => "0.125", "date" => "2026-01-01" } ] })
      financial = accounts(:investment)
      link = AccountProvider.create!(account: financial, provider: source)
      financial_before = financial.attributes
      entries = financial.entries.order(:id).pluck(:id)
      copier = Provider::AccountData::MigrationCopier.new(provider_key: "onchain_wallet", legacy_item_id: item.id)
      10.times do
        copier.run
        break if copier.control.reload.shadow?
      end
      assert copier.control.shadow?
      mapping = copier.control.provider_migration_mappings.find_by!(role: "external_account", legacy_id: source.id)
      target = mapping.target
      descriptor = target.sensitive_details.fetch("source_descriptor")
      assert_equal "onchain_#{source.id}", descriptor["ingestion_namespace"]
      assert_equal source.wallet_address, descriptor["wallet_address"]
      assert_equal target.external_id, Provider::AccountData::OnchainWallet::SourceDescriptor.external_id(descriptor)
      assert_equal BigDecimal("6000"), target.current_balance
      assert_not descriptor.key?("quantity")
      assert_not descriptor.key?("raw_movements_payload")
      assert_equal link.id, target.account_provider.id
      assert_equal financial_before, financial.reload.attributes
      assert_equal entries, financial.entries.order(:id).pluck(:id)
      assert_equal source.raw_movements_payload, copier.snapshot_for(mapping).fetch("attributes").fetch("raw_movements_payload")
      assert_provider_column_encrypted(target, :sensitive_details, source.wallet_address)
      assert copier.control.provider_connection.disabled?
    end
  end
end
