require "test_helper"
require "uri"

class Provider::OpenBankingIoAdapterTest < ActiveSupport::TestCase
  include ProviderAdapterTestInterface

  setup do
    @family = families(:dylan_family)
    @item = OpenBankingIoItem.create!(
      family: @family,
      name: "Test open-banking.io",
      api_base_url: "https://api.example.com",
      api_key: "test-api-key",
      private_key: "test-private-key"
    )
    @provider_account = OpenBankingIoAccount.create!(
      open_banking_io_item: @item,
      name: "Everyday Account",
      account_id: "acc_1",
      account_type: "CACC",
      currency: "EUR",
      current_balance: 1000,
      institution_metadata: {
        "name" => "Test Bank",
        "domain" => "testbank.de",
        "url" => "https://testbank.de"
      }
    )
    @account = accounts(:depository)
    @adapter = Provider::OpenBankingIoAdapter.new(@provider_account, account: @account)
  end

  def adapter
    @adapter
  end

  test_provider_adapter_interface
  test_syncable_interface
  test_institution_metadata_interface

  test "returns correct provider name" do
    assert_equal "open_banking_io", @adapter.provider_name
  end

  test "returns correct provider type" do
    assert_equal "OpenBankingIoAccount", @adapter.provider_type
  end

  test "returns the open-banking.io item" do
    assert_equal @item, @adapter.item
  end

  test "can_delete_holdings? returns false" do
    assert_equal false, @adapter.can_delete_holdings?
  end

  test "supports Depository, CreditCard, Loan and Investment" do
    assert_equal %w[Depository CreditCard Loan Investment], Provider::OpenBankingIoAdapter.supported_account_types
  end

  test "parses institution metadata" do
    assert_equal "testbank.de", @adapter.institution_domain
    assert_equal "Test Bank", @adapter.institution_name
    assert_equal "https://testbank.de", @adapter.institution_url
  end

  test "returns one connection config per credentialed item" do
    second_item = OpenBankingIoItem.create!(
      family: @family,
      name: "Second connection",
      api_base_url: "https://api2.example.com",
      api_key: "second-key",
      private_key: "second-private-key"
    )

    configs = Provider::OpenBankingIoAdapter.connection_configs(family: @family)

    assert_equal [ "open_banking_io_#{second_item.id}", "open_banking_io_#{@item.id}" ], configs.map { |c| c[:key] }
    assert_equal [ second_item.name, @item.name ], configs.map { |c| c[:name] }

    new_account_uri = URI.parse(configs.first[:new_account_path].call("Depository", "/accounts"))
    assert_equal "/open_banking_io_items/select_accounts", new_account_uri.path
    assert_includes new_account_uri.query, "open_banking_io_item_id=#{second_item.id}"

    existing_account_uri = URI.parse(configs.first[:existing_account_path].call(accounts(:depository).id))
    assert_equal "/open_banking_io_items/select_existing_account", existing_account_uri.path
    assert_includes existing_account_uri.query, "open_banking_io_item_id=#{second_item.id}"
  end
end
