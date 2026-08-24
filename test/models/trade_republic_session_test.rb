require "test_helper"

class TradeRepublicSessionTest < ActiveSupport::TestCase
  test "builds a desktop device fingerprint with a current browser version" do
    session = Provider::TradeRepublicSession.new(phone_number: "+491701234567", pin: "1234")
    headers = session.login_headers
    payload = JSON.parse(Base64.strict_decode64(headers.fetch("X-TR-Device-Info")))

    assert_equal "Chrome", payload.fetch("browser")
    expected_browser_version = Provider::TradeRepublicSession::USER_AGENT[/Chrome\/([\d.]+)/, 1]
    assert_equal expected_browser_version, payload.fetch("browserVersion")
    assert_equal "Desktop", payload.fetch("device")
    assert_equal "desktop", payload.fetch("deviceType")
    assert payload.fetch("stableDeviceId").match?(/\A[0-9a-f]{128}\z/)
  end

  test "keeps the device identity stable across session instances" do
    first = Provider::TradeRepublicSession.new(phone_number: "+491701234567", pin: "1234")
    second = Provider::TradeRepublicSession.new(phone_number: "+491701234567", pin: "1234")

    first_device = JSON.parse(Base64.strict_decode64(first.login_headers.fetch("X-TR-Device-Info")))
    second_device = JSON.parse(Base64.strict_decode64(second.login_headers.fetch("X-TR-Device-Info")))

    assert_equal first_device.fetch("stableDeviceId"), second_device.fetch("stableDeviceId")
  end
end
