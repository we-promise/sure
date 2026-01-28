require "test_helper"

class Provider::CoinstatsAdapterTest < ActiveSupport::TestCase
  include ProviderAdapterTestInterface

  setup do
    @family = families(:dylan_family)
    @coinstats_item = CoinstatsItem.create!(
      family: @family,
      name: "Test CoinStats Bank",
      api_key: "test_api_key_123"
    )
    @coinstats_account = CoinstatsAccount.create!(
      coinstats_item: @coinstats_item,
      name: "CoinStats Crypto Account",
      account_id: "cs_mock_1",
      currency: "USD",
      current_balance: 1000,
      institution_metadata: {
        "name" => "CoinStats Test Wallet",
        "domain" => "coinstats.app",
        "url" => "https://coinstats.app",
        "logo" => "https://example.com/logo.png"
      }
    )
    @account = accounts(:crypto)
    @adapter = Provider::CoinstatsAdapter.new(@coinstats_account, account: @account)
  end

  def adapter
    @adapter
  end

  # Run shared interface tests
  test_provider_adapter_interface
  test_syncable_interface
  test_institution_metadata_interface

  # Provider-specific tests
  test "returns correct provider name" do
    assert_equal "coinstats", @adapter.provider_name
  end

  test "returns correct provider type" do
    assert_equal "CoinstatsAccount", @adapter.provider_type
  end

  test "returns coinstats item" do
    assert_equal @coinstats_account.coinstats_item, @adapter.item
  end

  test "returns account" do
    assert_equal @account, @adapter.account
  end

  test "can_delete_holdings? returns false" do
    assert_equal false, @adapter.can_delete_holdings?
  end

  test "parses institution domain from institution_metadata" do
    assert_equal "coinstats.app", @adapter.institution_domain
  end

  test "parses institution name from institution_metadata" do
    assert_equal "CoinStats Test Wallet", @adapter.institution_name
  end

  test "parses institution url from institution_metadata" do
    assert_equal "https://coinstats.app", @adapter.institution_url
  end

  test "returns logo_url from institution_metadata" do
    assert_equal "https://example.com/logo.png", @adapter.logo_url
  end

  test "derives domain from url if domain is blank" do
    @coinstats_account.update!(institution_metadata: {
      "url" => "https://www.example.com/path"
    })

    adapter = Provider::CoinstatsAdapter.new(@coinstats_account, account: @account)
    assert_equal "example.com", adapter.institution_domain
  end

  test "supported_account_types includes Crypto" do
    assert_includes Provider::CoinstatsAdapter.supported_account_types, "Crypto"
  end

  test "connection_configs returns configurations when family can connect" do
    @family.stubs(:can_connect_coinstats?).returns(true)

    configs = Provider::CoinstatsAdapter.connection_configs(family: @family)

    assert_equal 1, configs.length
    assert_equal "coinstats", configs.first[:key]
    assert_equal "CoinStats", configs.first[:name]
    assert configs.first[:can_connect]
  end

  test "connection_configs returns empty when family cannot connect" do
    @family.stubs(:can_connect_coinstats?).returns(false)

    configs = Provider::CoinstatsAdapter.connection_configs(family: @family)

    assert_equal [], configs
  end

  test "build_provider returns nil when family is nil" do
    result = Provider::CoinstatsAdapter.build_provider(family: nil)
    assert_nil result
  end

  test "build_provider returns nil when no coinstats_items with api_key" do
    empty_family = families(:empty)
    result = Provider::CoinstatsAdapter.build_provider(family: empty_family)
    assert_nil result
  end

  test "build_provider returns Provider::Coinstats when credentials configured" do
    result = Provider::CoinstatsAdapter.build_provider(family: @family)

    assert_instance_of Provider::Coinstats, result
  end
end
