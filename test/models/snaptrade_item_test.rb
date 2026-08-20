require "test_helper"

class SnaptradeItemTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
  end

  test "validates presence of name" do
    item = SnaptradeItem.new(family: @family)
    assert_not item.valid?
    assert_includes item.errors[:name], "can't be blank"
  end

  test "requires client_id and consumer_key together" do
    assert SnaptradeItem.new(family: @family, name: "Test").valid?
    assert_not SnaptradeItem.new(family: @family, name: "Test", client_id: "cid").valid?
    assert_not SnaptradeItem.new(family: @family, name: "Test", consumer_key: "ck").valid?
    assert SnaptradeItem.new(family: @family, name: "Test", client_id: "cid", consumer_key: "ck").valid?
  end

  test "auth_method is nil until the item is connected" do
    item = SnaptradeItem.new(family: @family, name: "Test")

    assert_nil item.auth_method
    assert_nil item.snaptrade_provider
    assert_not item.credentials_configured?
  end

  test "api credentials select the device flow" do
    item = SnaptradeItem.new(family: @family, name: "Test", client_id: "cid", consumer_key: "ck")

    assert_equal :device_flow, item.auth_method
    assert item.device_flow?
    assert_not item.legacy_oauth?
    assert item.credentials_configured?
    assert_instance_of Provider::Snaptrade, item.snaptrade_provider
  end

  test "a bearer token without api credentials is a deprecated PKCE connection" do
    item = SnaptradeItem.new(family: @family, name: "Test", oauth_access_token: "test-access-token")

    assert_equal :legacy_oauth, item.auth_method
    assert item.legacy_oauth?
    assert_not item.device_flow?
    assert item.credentials_configured?
    assert_instance_of Provider::SnaptradeOauth, item.snaptrade_provider
  end

  test "api credentials win over a leftover PKCE token when a connection migrates" do
    item = SnaptradeItem.new(
      family: @family,
      name: "Test",
      client_id: "cid",
      consumer_key: "ck",
      oauth_access_token: "stale-pkce-token"
    )

    assert_equal :device_flow, item.auth_method
    assert_instance_of Provider::Snaptrade, item.snaptrade_provider
  end

  test "fully_configured? needs a registered user under the device flow" do
    item = SnaptradeItem.new(family: @family, name: "Test", client_id: "cid", consumer_key: "ck")
    assert_not item.fully_configured?

    item.assign_attributes(snaptrade_user_id: "u", snaptrade_user_secret: "s")
    assert item.fully_configured?
  end

  test "fully_configured? needs only a token on a deprecated PKCE connection" do
    assert snaptrade_items(:legacy_oauth_item).fully_configured?
    assert_not snaptrade_items(:unauthorized_item).fully_configured?
  end

  test "syncable scope covers both auth models but not unconnected items" do
    assert_includes SnaptradeItem.syncable, snaptrade_items(:configured_item)
    assert_includes SnaptradeItem.syncable, snaptrade_items(:legacy_oauth_item)
    assert_not_includes SnaptradeItem.syncable, snaptrade_items(:unauthorized_item)
  end

  test "syncable scope excludes items scheduled for deletion" do
    item = snaptrade_items(:configured_item)
    item.update!(scheduled_for_deletion: true)

    assert_not_includes SnaptradeItem.syncable, item
  end

  test "an unlinked account awaiting activities does not keep the item syncing" do
    item = snaptrade_items(:configured_item)
    account = snaptrade_accounts(:fidelity_401k)
    account.update!(activities_fetch_pending: true)

    assert_nil account.current_account
    assert_not item.syncing?
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
