require "test_helper"

class SnaptradeItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "validates presence of name" do
    item = SnaptradeItem.new(family: @family, client_id: "test", consumer_key: "test")
    assert_not item.valid?
    assert_includes item.errors[:name], "can't be blank"
  end

  test "validates presence of client_id on create" do
    item = SnaptradeItem.new(family: @family, name: "Test", consumer_key: "test")
    assert_not item.valid?
    assert_includes item.errors[:client_id], "can't be blank"
  end

  test "validates presence of consumer_key on create" do
    item = SnaptradeItem.new(family: @family, name: "Test", client_id: "test")
    assert_not item.valid?
    assert_includes item.errors[:consumer_key], "can't be blank"
  end

  test "credentials_configured? returns true when credentials are set" do
    item = SnaptradeItem.new(
      family: @family,
      name: "Test",
      client_id: "test_client_id",
      consumer_key: "test_consumer_key"
    )
    assert item.credentials_configured?
  end

  test "credentials_configured? returns false when credentials are missing" do
    item = SnaptradeItem.new(family: @family, name: "Test")
    assert_not item.credentials_configured?
  end

  test "user_registered? returns false when user_id and secret are blank" do
    item = SnaptradeItem.new(
      family: @family,
      name: "Test",
      client_id: "test",
      consumer_key: "test"
    )
    assert_not item.user_registered?
  end

  test "user_registered? returns true when user_id and secret are present" do
    item = SnaptradeItem.new(
      family: @family,
      name: "Test",
      client_id: "test",
      consumer_key: "test",
      snaptrade_user_id: "user_123",
      snaptrade_user_secret: "secret_abc"
    )
    assert item.user_registered?
  end

  test "snaptrade_provider returns nil when credentials not configured" do
    item = SnaptradeItem.new(family: @family, name: "Test")
    assert_nil item.snaptrade_provider
  end

  test "snaptrade_provider returns provider instance when configured" do
    item = SnaptradeItem.new(
      family: @family,
      name: "Test",
      client_id: "test_client_id",
      consumer_key: "test_consumer_key"
    )
    provider = item.snaptrade_provider
    assert_instance_of Provider::Snaptrade, provider
  end
end
