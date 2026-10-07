# frozen_string_literal: true

require "test_helper"

class OauthBasicTest < ActionDispatch::IntegrationTest
  test "oauth authorization endpoint requires authentication" do
    oauth_app = Doorkeeper::Application.create!(
      name: "Test API Client",
      redirect_uri: "https://client.example.com/callback",
      scopes: "read"
    )

    get "/oauth/authorize?client_id=#{oauth_app.uid}&redirect_uri=#{CGI.escape(oauth_app.redirect_uri)}&response_type=code&scope=read"

    # Should redirect to login page when not authenticated
    assert_redirected_to new_session_path
  end

  test "oauth authorization endpoint rejects a deactivated user's existing session" do
    oauth_app = Doorkeeper::Application.create!(
      name: "Test API Client",
      redirect_uri: "https://client.example.com/callback",
      scopes: "read"
    )
    user = users(:family_admin)
    sign_in user
    session_record = user.sessions.order(created_at: :desc).first

    # update_column bypasses callbacks, matching the exact scenario this
    # check exists to defend against (a stale session outliving deactivation).
    user.update_column(:active, false)

    get "/oauth/authorize?client_id=#{oauth_app.uid}&redirect_uri=#{CGI.escape(oauth_app.redirect_uri)}&response_type=code&scope=read"

    assert_redirected_to new_session_path
    assert_not Session.exists?(id: session_record.id), "stale session should be destroyed, not just skipped"
  end

  test "oauth token endpoint refuses a refresh_token exchange after the user is deactivated" do
    oauth_app = Doorkeeper::Application.create!(
      name: "Test API Client",
      redirect_uri: "https://client.example.com/callback",
      scopes: "read_write"
    )
    user = users(:family_admin)

    access_token = Doorkeeper::AccessToken.create!(
      application: oauth_app,
      resource_owner_id: user.id,
      expires_in: 2.hours,
      scopes: "read_write",
      use_refresh_token: true
    )
    refresh_token = access_token.plaintext_refresh_token

    # update_column bypasses callbacks (same idiom as the test above), then
    # explicitly exercises User#revoke_all_access_tokens — the mechanism
    # that actually revokes standard Doorkeeper grants/tokens on
    # deactivation, since this endpoint never goes through our custom
    # Authentication concern or MobileDevice#issue_token! at all.
    user.update_column(:active, false)
    user.revoke_all_access_tokens

    post "/oauth/token", params: {
      grant_type: "refresh_token",
      refresh_token: refresh_token,
      client_id: oauth_app.uid,
      client_secret: oauth_app.secret
    }

    assert_response :bad_request
    response_body = JSON.parse(response.body)
    assert_equal "invalid_grant", response_body["error"]
  end

  test "a public client refreshes through the oauth token endpoint" do
    oauth_app, access_token = create_public_client_token

    refreshed = refresh_through_token_endpoint(oauth_app, access_token.plaintext_refresh_token)

    assert_response :success
    assert refreshed["access_token"].present?
    assert refreshed["refresh_token"].present?
    assert_equal access_token.expires_in, refreshed["expires_in"]
  end

  test "using a refreshed token on mcp revokes the old refresh token" do
    oauth_app, access_token = create_public_client_token
    refreshed = refresh_through_token_endpoint(oauth_app, access_token.plaintext_refresh_token)

    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }.to_json,
      headers: { "Authorization" => "Bearer #{refreshed["access_token"]}", "Content-Type" => "application/json" }
    assert_response :success

    refresh_through_token_endpoint(oauth_app, access_token.plaintext_refresh_token)
    assert_response :bad_request
    assert_equal "invalid_grant", JSON.parse(response.body)["error"]
  end

  test "using a refreshed token on the api revokes the old refresh token" do
    oauth_app, access_token = create_public_client_token
    refreshed = refresh_through_token_endpoint(oauth_app, access_token.plaintext_refresh_token)

    get "/api/v1/accounts", headers: { "Authorization" => "Bearer #{refreshed["access_token"]}" }
    assert_response :success

    refresh_through_token_endpoint(oauth_app, access_token.plaintext_refresh_token)
    assert_response :bad_request
    assert_equal "invalid_grant", JSON.parse(response.body)["error"]
  end

  test "oauth token endpoint exists and handles requests" do
    post "/oauth/token", params: {
      grant_type: "authorization_code",
      code: "invalid_code",
      redirect_uri: "https://example.com/callback",
      client_id: "invalid_client"
    }

    # Should return 401 for invalid client (correct OAuth behavior)
    assert_response :unauthorized
    response_body = JSON.parse(response.body)
    assert_equal "invalid_client", response_body["error"]
  end

  test "oauth applications can be created" do
    assert_difference("Doorkeeper::Application.count") do
      Doorkeeper::Application.create!(
        name: "Test App",
        redirect_uri: "https://example.com/callback",
        scopes: "read"
      )
    end
  end

  test "doorkeeper configuration is properly set up" do
    # Test that Doorkeeper is configured and working
    assert Doorkeeper.configuration.present?, "Doorkeeper configuration should exist"
    assert_equal 2.hours, Doorkeeper.configuration.access_token_expires_in
    assert_equal "read", Doorkeeper.configuration.default_scopes.first.to_s
  end

  private

    def create_public_client_token
      oauth_app = Doorkeeper::Application.create!(
        name: "MCP Client",
        redirect_uri: "https://client.example.com/callback",
        scopes: "read_write",
        confidential: false
      )
      access_token = Doorkeeper::AccessToken.create!(
        application: oauth_app,
        resource_owner_id: users(:family_admin).id,
        expires_in: Doorkeeper.configuration.access_token_expires_in,
        scopes: "read_write",
        use_refresh_token: true
      )
      [ oauth_app, access_token ]
    end

    def refresh_through_token_endpoint(oauth_app, refresh_token)
      post "/oauth/token", params: {
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: oauth_app.uid
      }
      JSON.parse(response.body)
    end
end
