require "test_helper"

class SnaptradeItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "validates presence of name" do
    item = SnaptradeItem.new(family: @family)
    assert_not item.valid?
    assert_includes item.errors[:name], "can't be blank"
  end

  test "allows oauth-only items without api credentials" do
    item = SnaptradeItem.new(family: @family, name: "Test")
    assert item.valid?
  end

  test "snaptrade_provider returns nil when oauth token not present" do
    item = SnaptradeItem.new(family: @family, name: "Test")
    assert_nil item.snaptrade_provider
  end

  test "snaptrade_provider returns provider instance when oauth token present" do
    item = SnaptradeItem.new(
      family: @family,
      name: "Test",
      oauth_access_token: "test-access-token"
    )
    provider = item.snaptrade_provider
    assert_instance_of Provider::Snaptrade, provider
  end

  test "credentials_configured? mirrors oauth_configured?" do
    item = SnaptradeItem.new(family: @family, name: "Test")
    assert_equal item.oauth_configured?, item.credentials_configured?
    assert_not item.credentials_configured?

    item.oauth_access_token = "test-access-token"
    assert_equal item.oauth_configured?, item.credentials_configured?
    assert item.credentials_configured?
  end
end
