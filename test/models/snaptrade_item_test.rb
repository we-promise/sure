require "test_helper"

class SnaptradeItemTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
  end

  test "validates presence of name" do
    item = SnaptradeItem.new(family: @family, client_id: "test", consumer_key: "test")
    assert_not item.valid?
    assert_includes item.errors[:name], "can't be blank"
  end

  test "requires client_id when consumer_key is present" do
    item = SnaptradeItem.new(family: @family, name: "Test", consumer_key: "test")
    assert_not item.valid?
    assert_includes item.errors[:client_id], "can't be blank"
  end

  test "requires consumer_key when client_id is present" do
    item = SnaptradeItem.new(family: @family, name: "Test", client_id: "test")
    assert_not item.valid?
    assert_includes item.errors[:consumer_key], "can't be blank"
  end

  test "allows oauth-only items without api credentials" do
    item = SnaptradeItem.new(family: @family, name: "Test")
    assert item.valid?
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

  test "an unlinked account awaiting activities does not keep the item syncing" do
    item = snaptrade_items(:configured_item)
    account = snaptrade_accounts(:fidelity_401k)
    account.update!(activities_fetch_pending: true)

    assert_nil account.current_account
    assert_not item.syncing?
  end

  test "a transient verification failure keeps the unrecoverable user secret" do
    item = snaptrade_items(:configured_item)
    provider = mock
    provider.stubs(:list_connections).raises(
      Provider::Snaptrade::ApiError.new("rate limited", status_code: 429)
    )
    item.stubs(:snaptrade_provider).returns(provider)

    assert_equal :unknown, item.verify_user_status
    assert_raises(Provider::Snaptrade::ApiError) { item.ensure_user_registered! }
    assert_equal "user_123", item.reload.snaptrade_user_id
    assert_equal "secret_abc", item.snaptrade_user_secret
  end

  test "a rejected user is cleared so registration can start over" do
    item = snaptrade_items(:configured_item)
    provider = mock
    provider.stubs(:list_connections).raises(
      Provider::Snaptrade::AuthenticationError.new("no such user")
    )
    provider.stubs(:register_user).returns({ user_id: "family_1_999", user_secret: "fresh" })
    item.stubs(:snaptrade_provider).returns(provider)

    assert_equal :missing, item.verify_user_status
    assert item.ensure_user_registered!
    assert_equal "family_1_999", item.reload.snaptrade_user_id
  end

  test "changing API credentials drops the registration tied to the old client" do
    item = snaptrade_items(:configured_item)

    item.update!(client_id: "rotated_client_id")

    assert_nil item.reload.snaptrade_user_id
    assert_nil item.snaptrade_user_secret
    assert_not item.user_registered?
  end

  test "renaming an item leaves its registration alone" do
    item = snaptrade_items(:configured_item)

    item.update!(name: "Renamed")

    assert_equal "user_123", item.reload.snaptrade_user_id
  end

  test "syncable excludes items without API credentials" do
    item = snaptrade_items(:configured_item)
    assert_includes SnaptradeItem.syncable, item

    item.update_columns(consumer_key: nil)

    assert_not_includes SnaptradeItem.syncable, item.reload
  end

  test "sync_later_with_follow_up queues a follow-up after an active sync" do
    item = snaptrade_items(:configured_item)
    active_sync = item.syncs.create!
    active_sync.start!

    assert_enqueued_with job: SnaptradeFollowUpSyncJob do
      item.sync_later_with_follow_up
    end
  end
end
