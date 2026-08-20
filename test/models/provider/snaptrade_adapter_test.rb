require "test_helper"

class Provider::SnaptradeAdapterTest < ActiveSupport::TestCase
  test "supports Investment and Crypto accounts" do
    assert_includes Provider::SnaptradeAdapter.supported_account_types, "Investment"
    assert_includes Provider::SnaptradeAdapter.supported_account_types, "Crypto"
  end

  test "build_provider returns nil when family is nil" do
    assert_nil Provider::SnaptradeAdapter.build_provider(family: nil)
  end

  test "build_provider returns nil when the family has no connected snaptrade item" do
    snaptrade_items(:legacy_oauth_item).destroy!

    assert_nil Provider::SnaptradeAdapter.build_provider(family: families(:empty))
  end

  test "build_provider returns the device-flow client for a registered item" do
    provider = Provider::SnaptradeAdapter.build_provider(family: families(:dylan_family))

    assert_instance_of Provider::Snaptrade, provider
    assert_equal "user_123", provider.user_id
  end

  test "build_provider returns the deprecated client for a PKCE item" do
    item = snaptrade_items(:legacy_oauth_item)

    provider = Provider::SnaptradeAdapter.build_provider(family: families(:empty))

    assert_instance_of Provider::SnaptradeOauth, provider
    assert_equal item, provider.snaptrade_item
  end
end
