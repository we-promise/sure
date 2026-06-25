require "test_helper"

class Provider::SnaptradeOauthTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Snaptrade.new(client_id: "snap_client", consumer_key: "snap_secret")
    stub_request(:get, Provider::Snaptrade::OAUTH_DISCOVERY_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          issuer: "https://api.snaptrade.com",
          device_authorization_endpoint: "https://api.snaptrade.com/oauth/device_authorization/",
          token_endpoint: "https://api.snaptrade.com/oauth/token/"
        }.to_json
      )
  end

  test "starts device authorization using well known metadata" do
    stub_request(:post, "https://api.snaptrade.com/oauth/device_authorization/")
      .with(body: "client_id=PRSVp9N9F5ofw90KCaaOg4U9CN2afhgGVlqCOWSr&scope=read")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          device_code: "device-code",
          user_code: "ABCD-EFGH",
          verification_uri: "https://dashboard.snaptrade.com/activate",
          interval: 5,
          expires_in: 600
        }.to_json
      )

    response = @provider.start_device_authorization

    assert_equal "device-code", response["device_code"]
    assert_equal "ABCD-EFGH", response["user_code"]
    assert_equal 5, response["interval"]
  end

  test "polls token endpoint with device code grant" do
    stub_request(:post, "https://api.snaptrade.com/oauth/token/")
      .with(body: "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&device_code=device-code&client_id=PRSVp9N9F5ofw90KCaaOg4U9CN2afhgGVlqCOWSr")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          access_token: "access-token",
          refresh_token: "refresh-token",
          token_type: "Bearer",
          expires_in: 3600,
          scope: "read"
        }.to_json
      )

    response = @provider.poll_device_token(device_code: "device-code")

    assert_equal "access-token", response["access_token"]
    assert_equal "refresh-token", response["refresh_token"]
    assert_equal "Bearer", response["token_type"]
  end

  test "raises api error for oauth error responses" do
    stub_request(:post, "https://api.snaptrade.com/oauth/token/")
      .to_return(
        status: 400,
        headers: { "Content-Type" => "application/json" },
        body: { error: "authorization_pending" }.to_json
      )

    error = assert_raises Provider::Snaptrade::ApiError do
      @provider.poll_device_token(device_code: "device-code")
    end

    assert_equal 400, error.status_code
    assert_match "authorization_pending", error.message
  end
end
