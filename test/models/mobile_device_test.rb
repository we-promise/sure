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

  test "issue_token! returns nil and mints nothing for a deactivated user" do
    user = users(:family_member)
    device = MobileDevice.upsert_device!(user, {
      device_id: "test-device-issue-token",
      device_name: "Test Device",
      device_type: "ios",
      os_version: "17.0",
      app_version: "1.0.0"
    })
    user.update_column(:active, false)

    assert_no_difference("Doorkeeper::AccessToken.count") do
      assert_nil device.issue_token!
    end
  end

  test "issue_token! mints normally for an active user" do
    user = users(:family_member)
    device = MobileDevice.upsert_device!(user, {
      device_id: "test-device-issue-token-active",
      device_name: "Test Device",
      device_type: "ios",
      os_version: "17.0",
      app_version: "1.0.0"
    })

    assert_difference("Doorkeeper::AccessToken.count", 1) do
      token_response = device.issue_token!
      assert token_response[:access_token].present?
    end
  end
end
