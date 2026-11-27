require "test_helper"

class TradeRepublicSessionTest < ActiveSupport::TestCase
  include TradeRepublicSessionTestHelper
  include NetHttpCaptureHelper

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

  test "derives the device identity from the connection's device ID" do
    first = Provider::TradeRepublicSession.new(phone_number: "+491701234567", pin: "1234", device_id: "device-a")
    second = Provider::TradeRepublicSession.new(phone_number: "+491701234567", pin: "1234", device_id: "device-b")

    first_device = JSON.parse(Base64.strict_decode64(first.login_headers.fetch("X-TR-Device-Info")))
    second_device = JSON.parse(Base64.strict_decode64(second.login_headers.fetch("X-TR-Device-Info")))

    assert_equal Digest::SHA512.hexdigest("device-a"), first_device.fetch("stableDeviceId")
    assert_not_equal first_device.fetch("stableDeviceId"), second_device.fetch("stableDeviceId")
  end

  test "reads the session expiry from the tr_refresh token" do
    expires_at = Time.zone.parse("2026-10-16 20:45:58")

    assert_equal expires_at, Provider::TradeRepublicSession.expires_at(trade_republic_session_blob(expires_at: expires_at))
  end

  test "has no session expiry without a readable tr_refresh token" do
    assert_nil Provider::TradeRepublicSession.expires_at(nil)
    assert_nil Provider::TradeRepublicSession.expires_at(trade_republic_items(:configured_item).session_blob)
    assert_nil Provider::TradeRepublicSession.expires_at(JSON.generate("tr_refresh" => "not-a-jwt"))
    assert_nil Provider::TradeRepublicSession.expires_at(JSON.generate("tr_refresh" => "a.#{Base64.urlsafe_encode64("[]")}.c"))
  end

  test "session requests go through HTTPS_PROXY when HTTP_PROXY is unset" do
    stub_request(:get, "https://api.traderepublic.com/api/v1/auth/web/session").to_return(status: 200, body: "{}")
    calls, connection = capture_net_http_new("api.traderepublic.com", 443)

    with_proxy_env(https: PROXY) { trade_republic_session.get("/api/v1/auth/web/session") }

    assert_equal [ [ "api.traderepublic.com", 443, "proxy.internal", 8888, nil, nil ] ], calls
    assert connection.use_ssl?
  end

  test "NO_PROXY=* sends session requests direct" do
    stub_request(:get, "https://api.traderepublic.com/api/v1/auth/web/session").to_return(status: 200, body: "{}")
    calls, = capture_net_http_new("api.traderepublic.com", 443)

    with_proxy_env(https: PROXY, http: PROXY, no_proxy: "*") { trade_republic_session.get("/api/v1/auth/web/session") }

    assert_equal [ [ "api.traderepublic.com", 443, nil, nil, nil, nil ] ], calls
  end

  private
    def trade_republic_session
      Provider::TradeRepublicSession.new(phone_number: "+491701234567", pin: "1234")
    end
end
