require "test_helper"

class OauthCallbacksControllerTest < ActionDispatch::IntegrationTest
  FAKE_AUTH_URL = "https://auth.truelayer.com/?response_type=code&client_id=test"

  setup do
    sign_in users(:family_admin)
    provider_family_configs(:truelayer_family_one)
    # Stub the stateless adapter helper used by #new — authorize_url is called
    # on the adapter (Truelayer::Adapter) directly, not on Provider::Auth::OAuth2.
    Provider::Truelayer::Adapter.any_instance.stubs(:authorize_url).returns(FAKE_AUTH_URL)
  end

  test "new redirects to TrueLayer auth URL" do
    post start_provider_oauth_path(provider_key: "truelayer")
    assert_response :redirect
    assert_match "auth.truelayer.com", response.location
  end

  test "new does NOT create a Provider::Connection (flow state lives in session)" do
    assert_no_difference "Provider::Connection.count" do
      post start_provider_oauth_path(provider_key: "truelayer")
    end
  end

  test "new stashes flow state in session under a flow_id" do
    post start_provider_oauth_path(provider_key: "truelayer")
    flows = session[:provider_flows]
    assert flows.is_a?(Hash) && flows.any?
    flow = flows.values.first
    assert_equal "truelayer", flow["provider_key"]
    assert_kind_of Integer, flow["created_at"]
  end

  test "new stores psu_ip in flow state when client IP is public" do
    post start_provider_oauth_path(provider_key: "truelayer"),
         headers: { "REMOTE_ADDR" => "203.0.113.42" }
    flow = session[:provider_flows].values.first
    assert_equal "203.0.113.42", flow["psu_ip"]
  end

  test "new omits psu_ip when client IP is private or loopback" do
    post start_provider_oauth_path(provider_key: "truelayer"),
         headers: { "REMOTE_ADDR" => "127.0.0.1" }
    flow = session[:provider_flows].values.first
    assert_nil flow["psu_ip"]
  end

  test "new omits psu_ip for CGNAT (100.64.0.0/10) addresses" do
    post start_provider_oauth_path(provider_key: "truelayer"),
         headers: { "REMOTE_ADDR" => "100.64.1.42" }
    flow = session[:provider_flows].values.first
    assert_nil flow["psu_ip"]
  end

  test "new omits psu_ip for IPv4 link-local (cloud metadata) addresses" do
    post start_provider_oauth_path(provider_key: "truelayer"),
         headers: { "REMOTE_ADDR" => "169.254.169.254" }
    flow = session[:provider_flows].values.first
    assert_nil flow["psu_ip"]
  end

  test "new omits psu_ip for IPv6 link-local addresses" do
    post start_provider_oauth_path(provider_key: "truelayer"),
         headers: { "REMOTE_ADDR" => "fe80::1" }
    flow = session[:provider_flows].values.first
    assert_nil flow["psu_ip"]
  end

  test "new persists redirect_uri in flow state" do
    post start_provider_oauth_path(provider_key: "truelayer")
    flow = session[:provider_flows].values.first
    assert_equal provider_auth_url(provider_key: "truelayer"), flow["redirect_uri"]
  end
end
