require "test_helper"

class SnaptradeItemOauthTest < ActiveSupport::TestCase
  test "complete_oauth_device_flow stores token metadata" do
    item = snaptrade_items(:configured_item)
    provider = mock("snaptrade_provider")
    provider.expects(:poll_device_token).with(device_code: "device-code").returns(
      "access_token" => "access-token",
      "refresh_token" => "refresh-token",
      "token_type" => "Bearer",
      "scope" => "read",
      "expires_in" => 3600
    )
    Provider::Snaptrade.expects(:new).returns(provider)

    expected_expiry = 1.hour.from_now

    travel_to expected_expiry - 1.hour do
      item.complete_oauth_device_flow!(device_code: "device-code")
    end

    item.reload
    assert_equal "access-token", item.oauth_access_token
    assert_equal "refresh-token", item.oauth_refresh_token
    assert_equal "Bearer", item.oauth_token_type
    assert_equal "read", item.oauth_scope
    assert_in_delta expected_expiry.to_f, item.oauth_token_expires_at.to_f, 1
    assert item.oauth_token_active?
  end
end
