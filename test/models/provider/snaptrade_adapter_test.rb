require "test_helper"

class Provider::SnaptradeAdapterTest < ActiveSupport::TestCase
  test "supports Investment and Crypto accounts" do
    assert_includes Provider::SnaptradeAdapter.supported_account_types, "Investment"
    assert_includes Provider::SnaptradeAdapter.supported_account_types, "Crypto"
  end

  test "build_provider returns nil when family is nil" do
    assert_nil Provider::SnaptradeAdapter.build_provider(family: nil)
  end

  test "build_provider returns nil when OAuth app is not configured" do
    Provider::Snaptrade.stubs(:oauth_configured?).returns(false)

    assert_nil Provider::SnaptradeAdapter.build_provider(family: families(:dylan_family))
  end

  test "build_provider returns nil when family has no authorized snaptrade item" do
    Provider::Snaptrade.stubs(:oauth_configured?).returns(true)

    assert_nil Provider::SnaptradeAdapter.build_provider(family: families(:empty))
  end

  test "build_provider returns a Provider::Snaptrade wrapping the authorized item" do
    Provider::Snaptrade.stubs(:oauth_configured?).returns(true)
    family = families(:dylan_family)
    item = snaptrade_items(:configured_item)

    provider = Provider::SnaptradeAdapter.build_provider(family: family)

    assert_instance_of Provider::Snaptrade, provider
    assert_equal item, provider.snaptrade_item
  end
end
