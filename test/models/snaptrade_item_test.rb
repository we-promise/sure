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

  test "a Personal API key authorizes the item without OAuth tokens" do
    item = SnaptradeItem.new(family: @family, name: "Personal", client_id: "personal-client", consumer_key: "personal-key",
                             oauth_token_type: SnaptradeItem::PERSONAL_KEY_TOKEN_TYPE)

    assert item.personal_key_configured?
    assert item.credentials_configured?
    assert_not item.oauth_configured?
    assert_instance_of Provider::Snaptrade, item.snaptrade_provider
  end

  test "apply_personal_key! replaces OAuth tokens and the legacy user with the key" do
    item = snaptrade_items(:configured_item)
    item.update!(snaptrade_user_id: "legacy-user", snaptrade_user_secret: "legacy-secret", status: :requires_update)

    item.apply_personal_key!(client_id: "personal-client", consumer_key: "personal-key")
    item.reload

    assert item.personal_key_configured?
    assert_not item.oauth_configured?
    assert_equal [ "personal-client", "personal-key", nil, nil, nil, nil, "good" ],
                 [ item.client_id, item.consumer_key, item.oauth_refresh_token, item.oauth_token_expires_at,
                   item.snaptrade_user_id, item.snaptrade_user_secret, item.status ]
    assert_includes SnaptradeItem.syncable, item
  end

  # Pre-OAuth items that stored keys but never registered a user (or whose
  # re-registration failed) have keys and no user secret, like a Personal key.
  test "a pre-OAuth item that never registered a user is not a Personal API key" do
    legacy = @family.snaptrade_items.create!(name: "Legacy", client_id: "commercial-client", consumer_key: "commercial-key", status: :requires_update)
    blank_secret = @family.snaptrade_items.create!(name: "Blank", client_id: "c", consumer_key: "k", snaptrade_user_secret: "")

    assert_not legacy.personal_key_configured?
    assert_not_includes SnaptradeItem.syncable, legacy
    assert_equal blank_secret.personal_key_configured?, SnaptradeItem.syncable.include?(blank_secret)
  end

  test "syncable includes Personal API key items and excludes pre-OAuth items" do
    personal = @family.snaptrade_items.create!(name: "Personal", client_id: "personal-client", consumer_key: "personal-key",
                                               oauth_token_type: SnaptradeItem::PERSONAL_KEY_TOKEN_TYPE)
    legacy = @family.snaptrade_items.create!(
      name: "Legacy", client_id: "commercial-client", consumer_key: "commercial-key",
      snaptrade_user_id: "user-1", snaptrade_user_secret: "secret-1"
    )
    unauthorized = @family.snaptrade_items.create!(name: "Unauthorized")

    syncable = SnaptradeItem.syncable
    assert_includes syncable, personal
    assert_includes syncable, snaptrade_items(:configured_item)
    assert_not_includes syncable, legacy
    assert_not_includes syncable, unauthorized
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

  test "declares OAuth credential fields as encrypted" do
    skip "Encryption not configured" unless SnaptradeItem.encryption_ready?

    encrypted = Array(SnaptradeItem.encrypted_attributes).map(&:to_s)
    assert_includes encrypted, "client_id"
    assert_includes encrypted, "consumer_key"
    assert_includes encrypted, "snaptrade_user_secret"
    assert_includes encrypted, "oauth_access_token"
    assert_includes encrypted, "oauth_refresh_token"
    assert_includes encrypted, "raw_payload"
    assert_includes encrypted, "raw_institution_payload"
  end
end
