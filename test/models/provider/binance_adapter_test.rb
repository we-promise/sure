require "test_helper"

class Provider::BinanceAdapterTest < ActiveSupport::TestCase
  include ProviderAdapterTestInterface

  setup do
    @family = families(:dylan_family)
    @binance_item = BinanceItem.create!(
      family: @family,
      name: "Test Binance",
      api_key: "test_key",
      api_secret: "test_secret"
    )
    @binance_account = BinanceAccount.create!(
      binance_item: @binance_item,
      name: "Binance Spot",
      account_id: "uid_123",
      currency: "USD",
      current_balance: 1000,
      institution_metadata: {
        "name" => "Binance",
        "domain" => "binance.com",
        "url" => "https://www.binance.com"
      }
    )
    @account = accounts(:crypto)
    @adapter = Provider::BinanceAdapter.new(@binance_account, account: @account)
  end

  def adapter
    @adapter
  end

  test_provider_adapter_interface
  test_syncable_interface
  test_institution_metadata_interface

  test "returns correct provider name" do
    assert_equal "binance", @adapter.provider_name
  end

  test "returns correct provider type" do
    assert_equal "BinanceAccount", @adapter.provider_type
  end

  test "returns binance item" do
    assert_equal @binance_account.binance_item, @adapter.item
  end

  test "returns account" do
    assert_equal @account, @adapter.account
  end

  test "can_delete_holdings? returns false" do
    assert_equal false, @adapter.can_delete_holdings?
  end

  test "supported_account_types includes Crypto" do
    assert_includes Provider::BinanceAdapter.supported_account_types, "Crypto"
  end

  test "connection_configs returns configurations when family can connect" do
    @family.stubs(:can_connect_binance?).returns(true)

    configs = Provider::BinanceAdapter.connection_configs(family: @family)

    assert_equal 1, configs.length
    assert_equal "binance", configs.first[:key]
    assert_equal "Binance", configs.first[:name]
    assert configs.first[:can_connect]
  end

  test "connection_configs returns empty when family cannot connect" do
    @family.stubs(:can_connect_binance?).returns(false)

    assert_equal [], Provider::BinanceAdapter.connection_configs(family: @family)
  end

  test "build_provider returns nil when family is nil" do
    assert_nil Provider::BinanceAdapter.build_provider(family: nil)
  end

  test "build_provider returns nil when no item exists" do
    assert_nil Provider::BinanceAdapter.build_provider(family: families(:empty))
  end

  test "build_provider returns Provider::Binance when credentials configured" do
    assert_instance_of Provider::Binance, Provider::BinanceAdapter.build_provider(family: @family)
  end

  test "institution metadata falls back to item defaults" do
    @binance_item.set_binance_institution_defaults!
    @binance_account.update!(institution_metadata: {})

    assert_equal "Binance", @adapter.institution_name
    assert_equal "binance.com", @adapter.institution_domain
    assert_equal "https://www.binance.com", @adapter.institution_url
    assert_equal "#F0B90B", @adapter.institution_color
  end
end
