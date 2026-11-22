# frozen_string_literal: true

require "test_helper"

class OauthMobileTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:empty)
    sign_in(@user)

    @oauth_app = Doorkeeper::Application.create!(
      name: "Sure Mobile App",
      redirect_uri: "sureapp://oauth/callback",
      scopes: "read"
    )
  end

  test "mobile oauth authorization with custom scheme redirect" do
    get "/oauth/authorize", params: {
      client_id: @oauth_app.uid,
      redirect_uri: @oauth_app.redirect_uri,
      response_type: "code",
      scope: "read",
      display: "mobile"
    }

    assert_response :success

    # Check that Turbo is disabled in the form
    assert_match(/data-turbo="false"/, response.body)
    assert_match(/sureapp:\/\/oauth\/callback/, response.body)
  end

  test "mobile oauth detects custom scheme in redirect_uri" do
    get "/oauth/authorize", params: {
      client_id: @oauth_app.uid,
      redirect_uri: "sureapp://oauth/callback",
      response_type: "code",
      scope: "read"
    }

    assert_response :success

    # Should detect mobile flow from redirect_uri
    assert_match(/data-turbo="false"/, response.body)
  end

  test "mobile oauth authorization flow completes successfully" do
    post "/oauth/authorize", params: {
      client_id: @oauth_app.uid,
      redirect_uri: @oauth_app.redirect_uri,
      response_type: "code",
      scope: "read",
      display: "mobile"
    }

    # Should redirect to the custom scheme
    assert_response :redirect
    assert response.location.start_with?("sureapp://oauth/callback")
  end

  test "mobile oauth preserves display parameter through forms" do
    get "/oauth/authorize", params: {
      client_id: @oauth_app.uid,
      redirect_uri: @oauth_app.redirect_uri,
      response_type: "code",
      scope: "read",
      display: "mobile"
    }

    assert_response :success

    # Check that display parameter is preserved in hidden fields
    assert_match(/<input[^>]*name="display"[^>]*value="mobile"/, response.body)
  end

  test "signing in again on a device revokes its tokens refreshed through the OAuth token endpoint" do
    device = create_device
    refreshed, = refresh_through_oauth(device.issue_token![:refresh_token])

    assert_equal device.id, refreshed.mobile_device_id

    device.issue_token!

    assert refreshed.reload.revoked?
  end

  test "a device keeps its tokens across OAuth and app refreshes in any order" do
    device = create_device
    through_oauth, refresh_token = refresh_through_oauth(device.issue_token![:refresh_token])
    through_app = refresh_through_app(refresh_token)
    again_through_oauth, = refresh_through_oauth(through_app[:refresh_token])
    chain = [ through_oauth, Doorkeeper::AccessToken.by_token(through_app[:access_token]), again_through_oauth ]

    assert_equal [ device.id ] * 3, chain.map(&:mobile_device_id)

    device.issue_token!

    assert chain.map(&:reload).all?(&:revoked?)
    assert_equal 1, device.active_tokens.count
  end

  test "a refreshed token of another OAuth client gets no device" do
    client = Doorkeeper::Application.create!(name: "Other Client", redirect_uri: "https://example.com/callback", scopes: "read", confidential: false)
    token = Doorkeeper::AccessToken.create!(application: client, resource_owner_id: @user.id, scopes: "read", expires_in: 1.hour, use_refresh_token: true)

    refreshed, = refresh_through_oauth(token.plaintext_refresh_token, client: client)

    assert_nil refreshed.mobile_device_id
  end

  private
    def create_device
      MobileDevice.instance_variable_set(:@shared_oauth_application, nil)
      MobileDevice.create!(user: @user, device_id: "device-#{SecureRandom.hex(4)}", device_name: "Test Phone", device_type: "ios")
    end

    # The new token and its refresh token.
    def refresh_through_oauth(refresh_token, client: MobileDevice.shared_oauth_application)
      post "/oauth/token", params: { grant_type: "refresh_token", client_id: client.uid, refresh_token: refresh_token }
      assert_response :success
      body = JSON.parse(response.body)
      [ Doorkeeper::AccessToken.by_token(body["access_token"]), body["refresh_token"] ]
    end

    def refresh_through_app(refresh_token)
      post "/api/v1/auth/refresh", params: { refresh_token: refresh_token }
      assert_response :success
      JSON.parse(response.body).symbolize_keys
    end
end
