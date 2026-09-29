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
end
