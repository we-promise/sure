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

  test "orphaned_users only includes users for the same family" do
    item = SnaptradeItem.new(
      family: @family,
      name: "Test",
      client_id: "test",
      consumer_key: "test",
      snaptrade_user_id: "family_#{@family.id}_111",
      snaptrade_user_secret: "secret"
    )

    item.stubs(:list_all_users).returns([
      "family_#{@family.id}_111",
      "family_#{@family.id}_222",
      "family_999_333",
      "legacy_user_444"
    ])

    assert_equal([ "family_#{@family.id}_222" ], item.orphaned_users)
  end

  test "delete_orphaned_user rejects users outside the current family namespace" do
    item = SnaptradeItem.new(
      family: @family,
      name: "Test",
      client_id: "test",
      consumer_key: "test",
      snaptrade_user_id: "family_#{@family.id}_111",
      snaptrade_user_secret: "secret"
    )

    provider = mock
    provider.expects(:delete_user).never
    item.stubs(:snaptrade_provider).returns(provider)

    assert_not item.delete_orphaned_user("family_999_222")
    assert_not item.delete_orphaned_user("legacy_user_333")
  end

  test "ensure_user_registered! uses pre-provisioned personal-key credentials without re-registering" do
    item = SnaptradeItem.create!(
      family: @family,
      name: "Test",
      client_id: "test",
      consumer_key: "test",
      snaptrade_user_id: "personal_user",
      snaptrade_user_secret: "personal_secret"
    )

    provider = mock
    provider.expects(:list_connections)
            .with(user_id: "personal_user", user_secret: "personal_secret")
            .returns([])
    provider.expects(:register_user).never
    item.stubs(:snaptrade_provider).returns(provider)

    assert item.ensure_user_registered!
    assert_equal "personal_user", item.snaptrade_user_id
  end

  test "ensure_user_registered! surfaces a friendly error when a personal key cannot register" do
    item = SnaptradeItem.create!(
      family: @family,
      name: "Test",
      client_id: "test",
      consumer_key: "test"
    )

    provider = mock
    provider.expects(:register_user).raises(
      Provider::Snaptrade::PersonalKeyError.new("registerUser is not available for personal keys", status_code: 400)
    )
    item.stubs(:snaptrade_provider).returns(provider)

    error = assert_raises(StandardError) { item.ensure_user_registered! }
    assert_match(/personal key/i, error.message)
    assert_not item.user_registered?
  end
end
