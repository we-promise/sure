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

  test "build_provider returns a Personal-key item's provider when no OAuth app is configured" do
    Provider::Snaptrade.stubs(:oauth_configured?).returns(false)
    item = snaptrade_items(:configured_item)
    item.update!(oauth_access_token: nil, oauth_refresh_token: nil, oauth_token_type: SnaptradeItem::PERSONAL_KEY_TOKEN_TYPE,
                 client_id: "personal-client", consumer_key: "personal-consumer-key")

    provider = Provider::SnaptradeAdapter.build_provider(family: families(:dylan_family))

    assert_instance_of Provider::Snaptrade, provider
    assert_equal item, provider.snaptrade_item
  end

  test "build_provider picks the newest Personal-key item, as the settings controller does" do
    Provider::Snaptrade.stubs(:oauth_configured?).returns(false)
    family = families(:dylan_family)
    older = snaptrade_items(:configured_item)
    older.update!(created_at: 2.days.ago)
    older.apply_personal_key!(client_id: "old-client", consumer_key: "old-key")
    newer = family.snaptrade_items.create!(name: "Newer")
    newer.apply_personal_key!(client_id: "new-client", consumer_key: "new-key")

    assert_equal newer, Provider::SnaptradeAdapter.build_provider(family: family).snaptrade_item
  end
end
