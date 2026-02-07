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
end
