# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261123210000_assign_mobile_devices_to_refreshed_tokens")

class AssignMobileDevicesToRefreshedTokensMigrationTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @device = MobileDevice.create!(user: @user, device_id: "device-#{SecureRandom.hex(4)}", device_name: "Test Phone", device_type: "ios")
    MobileDevice.instance_variable_set(:@shared_oauth_application, nil)
    @mobile_client = MobileDevice.shared_oauth_application
  end

  test "gives every token refreshed from a device token that device and revokes it" do
    root = token(mobile_device_id: @device.id)
    child = token(previous: root)
    grandchild = token(previous: child)

    run_migration

    assert_equal [ @device.id ] * 2, [ child, grandchild ].map { |t| t.reload.mobile_device_id }
    assert [ child, grandchild ].all?(&:revoked?)
    assert_not root.reload.revoked?
  end

  test "revokes a refreshed descendant that a sign-in before the migration missed" do
    root = token(mobile_device_id: @device.id)
    orphan = token(previous: root)
    @device.issue_token!

    run_migration

    assert root.reload.revoked?
    assert orphan.reload.revoked?
    assert_not_includes @device.unrevoked_tokens, orphan
  end

  test "revokes a mobile client token whose device cannot be recovered" do
    root = token(mobile_device_id: @device.id)
    lost = token(previous: token(previous: root)).tap { |t| t.update_column(:previous_refresh_token, "") }

    run_migration

    assert_nil lost.reload.mobile_device_id
    assert lost.revoked?
  end

  test "leaves tokens outside a device's lineage alone" do
    other_client = Doorkeeper::Application.create!(name: "Other", redirect_uri: "https://example.com/callback", confidential: false)
    unrelated = token(application: other_client)
    refreshed_unrelated = token(application: other_client, previous: unrelated)
    other_device = MobileDevice.create!(user: @user, device_id: "device-#{SecureRandom.hex(4)}", device_name: "Tablet", device_type: "android")
    stamped = token(mobile_device_id: other_device.id, previous: token(mobile_device_id: @device.id))

    run_migration

    assert_nil unrelated.reload.mobile_device_id
    assert_nil refreshed_unrelated.reload.mobile_device_id
    assert_equal other_device.id, stamped.reload.mobile_device_id
    assert_not [ unrelated, refreshed_unrelated, stamped ].any?(&:revoked?)
  end

  private
    # Writes mobile_device_id after the insert, as tokens were saved before the
    # fix, so the inheritance callback does not fill it in.
    def token(application: @mobile_client, mobile_device_id: nil, previous: nil)
      Doorkeeper::AccessToken.create!(
        application: application,
        resource_owner_id: @user.id,
        scopes: "read_write",
        expires_in: 30.days.to_i,
        use_refresh_token: true,
        previous_refresh_token: previous&.refresh_token.to_s
      ).tap { |created| created.update_column(:mobile_device_id, mobile_device_id) }
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages { AssignMobileDevicesToRefreshedTokens.new.up }
    end
end
