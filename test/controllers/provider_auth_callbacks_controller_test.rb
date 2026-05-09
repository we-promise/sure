require "test_helper"

class ProviderAuthCallbacksControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  # ---- OAuth2 path (TrueLayer) -------------------------------------------

  test "GET /auth with OAuth2 provider and valid state exchanges code and creates connection" do
    Provider::Truelayer::Adapter.any_instance.stubs(:authorize_url).returns("https://auth.truelayer.com/")
    post start_provider_oauth_path(provider_key: "truelayer")
    flow_id = session[:provider_flows].keys.first

    Provider::Auth::OAuth2.any_instance.expects(:exchange_code).once
    Provider::Connection.any_instance.expects(:discover_accounts!).once

    assert_difference "Provider::Connection.count", 1 do
      get provider_auth_path(provider_key: "truelayer", code: "auth_code", state: flow_id)
    end
    conn = Provider::Connection.order(created_at: :desc).first
    assert_redirected_to setup_provider_connection_path(conn)
    assert_equal "truelayer", conn.provider_key
  end

  test "GET /auth with OAuth2 provider and unknown state redirects to providers" do
    Provider::Auth::OAuth2.any_instance.expects(:exchange_code).never
    assert_no_difference "Provider::Connection.count" do
      get provider_auth_path(provider_key: "truelayer", code: "code", state: "bad-state")
    end
    assert_redirected_to settings_providers_path
  end

  test "GET /auth OAuth2 reauth flow updates existing connection and redirects to show" do
    existing_conn = provider_connections(:monzo_connection)

    Provider::Auth::OAuth2.any_instance.stubs(:reauth_url).returns("https://auth.truelayer.com/reauth")
    post reauth_provider_connection_path(existing_conn)
    flow_id = session[:provider_flows].keys.first

    Provider::Auth::OAuth2.any_instance.expects(:exchange_code).once

    assert_no_difference "Provider::Connection.count" do
      get provider_auth_path(provider_key: "truelayer", code: "auth_code", state: flow_id)
    end
    assert_redirected_to provider_connection_path(existing_conn)
  end

  # ---- EmbeddedLink path (Plaid) -----------------------------------------

  test "GET /auth with EmbeddedLink provider re-renders Link view with is_resume true" do
    plaid_client = mock
    Provider::Registry.stubs(:plaid_provider_for_region).returns(plaid_client)
    plaid_client.stubs(:get_link_token).returns(OpenStruct.new(link_token: "lt"))

    get new_provider_link_path(provider_key: "plaid", region: "us")
    assert session[:active_link_flows]["plaid"].present?

    get provider_auth_path(provider_key: "plaid", oauth_state_id: "oauth_xyz")
    assert_response :success
    assert session[:provider_flows].any?
  end

  test "GET /auth with EmbeddedLink provider and no active flow redirects to providers" do
    get provider_auth_path(provider_key: "plaid")
    assert_redirected_to settings_providers_path
  end

  test "GET /auth returns 404 for unknown provider_key" do
    get provider_auth_path(provider_key: "no_such_provider")
    assert_response :not_found
  end
end
