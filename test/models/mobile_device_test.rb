require "test_helper"

class MobileDeviceTest < ActiveSupport::TestCase
  setup do
    MobileDevice.instance_variable_set(:@shared_oauth_application, nil)
  end

  teardown do
    MobileDevice.instance_variable_set(:@shared_oauth_application, nil)
  end

  test "shared_oauth_application auto-creates application when missing" do
    Doorkeeper::Application.where(name: "Sure Mobile").destroy_all

    assert_difference("Doorkeeper::Application.count", 1) do
      app = MobileDevice.shared_oauth_application
      assert_equal "Sure Mobile", app.name
      assert_equal MobileDevice::CALLBACK_URL, app.redirect_uri
      assert_equal "read_write", app.scopes.to_s
      assert_not app.confidential
    end
  end

  test "shared_oauth_application ignores a same-named client with another redirect uri" do
    Doorkeeper::Application.where(name: "Sure Mobile").destroy_all
    # Registered before the real app, e.g. via dynamic client registration on
    # an instance where nobody had signed in on mobile yet.
    impostor = Doorkeeper::Application.create!(
      name: "Sure Mobile",
      redirect_uri: "https://evil.example/callback",
      scopes: "read_write",
      confidential: false,
      created_at: 3.days.ago
    )
    real = Doorkeeper::Application.create!(
      name: "Sure Mobile",
      redirect_uri: MobileDevice::CALLBACK_URL,
      scopes: "read_write",
      confidential: false,
      created_at: 2.days.ago
    )

    assert_equal real, MobileDevice.shared_oauth_application
    assert_not_equal impostor, MobileDevice.shared_oauth_application
  end

  test "shared_oauth_application creates the real app when only an impostor exists" do
    Doorkeeper::Application.where(name: "Sure Mobile").destroy_all
    impostor = Doorkeeper::Application.create!(
      name: "Sure Mobile",
      redirect_uri: "https://evil.example/callback",
      scopes: "read_write",
      confidential: false
    )

    app = MobileDevice.shared_oauth_application

    assert_not_equal impostor, app
    assert_equal MobileDevice::CALLBACK_URL, app.redirect_uri
  end

  test "inactive users cannot receive new mobile tokens" do
    user = users(:family_member)
    device = user.mobile_devices.create!(
      device_id: "inactive-token-test",
      device_name: "Inactive test device",
      device_type: "ios"
    )
    user.update_column(:active, false)

    assert_no_difference "Doorkeeper::AccessToken.count" do
      assert_raises(User::InactiveError) { device.issue_token! }
    end
  end

  test "issue_token! does not report a genuine persistence failure as an inactive user" do
    user = users(:family_member)
    device = user.mobile_devices.create!(
      device_id: "persistence-failure-test",
      device_name: "Persistence failure test device",
      device_type: "ios"
    )
    assert user.active?

    Doorkeeper::AccessToken.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(Doorkeeper::AccessToken.new))

    assert_raises(ActiveRecord::RecordInvalid) { device.issue_token! }
  end

  test "a token that replaces a device token takes its device, and its revocation" do
    device = MobileDevice.create!(user: users(:family_admin), device_id: "device-#{SecureRandom.hex(4)}", device_name: "Test Phone", device_type: "ios")
    device.issue_token!
    previous = device.unrevoked_tokens.sole

    replacement = -> do
      Doorkeeper::AccessToken.create!(
        application: previous.application, resource_owner_id: previous.resource_owner_id, scopes: previous.scopes,
        expires_in: previous.expires_in, use_refresh_token: true, previous_refresh_token: previous.refresh_token
      )
    end

    live = replacement.call
    assert_equal device.id, live.mobile_device_id
    assert_not live.revoked?

    device.revoke_all_tokens!
    assert live.reload.revoked?

    late = replacement.call
    assert_equal device.id, late.mobile_device_id
    assert late.revoked?, "a refresh that lost the race with a new sign-in must not outlive it"
  end

  test "issue_token! revokes an expired token so its refresh token stops working" do
    device = users(:family_member).mobile_devices.create!(
      device_id: "expired-token-test",
      device_name: "Expired token test device",
      device_type: "ios"
    )
    expired = Doorkeeper::AccessToken.create!( # pipelock:ignore
      application: MobileDevice.shared_oauth_application,
      resource_owner_id: device.user_id,
      mobile_device_id: device.id,
      expires_in: 1.hour.to_i,
      scopes: "read_write",
      use_refresh_token: true,
      created_at: 2.hours.ago
    )
    assert expired.expired?

    device.issue_token!

    assert expired.reload.revoked?
  end
end
