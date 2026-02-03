require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)

    # Ensure the shared OAuth application exists
    Doorkeeper::Application.find_or_create_by!(name: "Sure Mobile") do |app|
      app.redirect_uri = "sureapp://oauth/callback"
      app.scopes = "read_write"
      app.confidential = false
    end

    # Clear the memoized class variable so it picks up the test record
    MobileDevice.instance_variable_set(:@shared_oauth_application, nil)
  end

  teardown do
    # Clear OmniAuth mock auth after each test
    OmniAuth.config.mock_auth[:openid_connect] = nil
  end

  def setup_omniauth_mock(provider:, uid:, email:, name:, first_name: nil, last_name: nil)
    OmniAuth.config.mock_auth[:openid_connect] = OmniAuth::AuthHash.new({
      provider: provider,
      uid: uid,
      info: {
        email: email,
        name: name,
        first_name: first_name,
        last_name: last_name
      }.compact
    })
  end

  test "login page" do
    get new_session_url
    assert_response :success
  end

  test "can sign in" do
    sign_in @user
    assert_redirected_to root_url
    assert Session.exists?(user_id: @user.id)

    get root_url
    assert_response :success
  end

  test "fails to sign in with bad password" do
    post sessions_url, params: { email: @user.email, password: "bad" }
    assert_response :unprocessable_entity
    assert_equal "Invalid email or password.", flash[:alert]
  end

  test "redirects when local login is disabled" do
    AuthConfig.stubs(:local_login_enabled?).returns(false)
    AuthConfig.stubs(:local_admin_override_enabled?).returns(false)

    post sessions_url, params: { email: @user.email, password: user_password_test }

    assert_redirected_to new_session_path
    assert_equal "Local password login is disabled. Please use single sign-on.", flash[:alert]
  end

  test "allows super admin local login when override enabled" do
    super_admin = users(:sure_support_staff)

    AuthConfig.stubs(:local_login_enabled?).returns(false)
    AuthConfig.stubs(:local_admin_override_enabled?).returns(true)

    post sessions_url, params: { email: super_admin.email, password: user_password_test }

    assert_redirected_to root_path
    assert Session.exists?(user_id: super_admin.id)
  end

  test "shows invalid credentials for super admin when override enabled but password is wrong" do
    super_admin = users(:sure_support_staff)

    AuthConfig.stubs(:local_login_enabled?).returns(false)
    AuthConfig.stubs(:local_admin_override_enabled?).returns(true)

    post sessions_url, params: { email: super_admin.email, password: "bad" }

    assert_response :unprocessable_entity
    assert_equal "Invalid email or password.", flash[:alert]
  end

  test "blocks non-super-admin local login when override enabled" do
    AuthConfig.stubs(:local_login_enabled?).returns(false)
    AuthConfig.stubs(:local_admin_override_enabled?).returns(true)

    post sessions_url, params: { email: @user.email, password: user_password_test }

    assert_redirected_to new_session_path
    assert_equal "Local password login is disabled. Please use single sign-on.", flash[:alert]
  end

  test "renders multiple SSO provider buttons" do
    AuthConfig.stubs(:local_login_form_visible?).returns(true)
    AuthConfig.stubs(:password_features_enabled?).returns(true)
    AuthConfig.stubs(:sso_providers).returns([
      { id: "oidc", strategy: "openid_connect", name: "openid_connect", label: "Sign in with Keycloak", icon: "key" },
      { id: "google", strategy: "google_oauth2", name: "google_oauth2", label: "Sign in with Google", icon: "google" }
    ])

    get new_session_path
    assert_response :success

    # Generic OIDC button
    assert_match %r{/auth/openid_connect}, @response.body
    assert_match /Sign in with Keycloak/, @response.body

    # Google-branded button
    assert_match %r{/auth/google_oauth2}, @response.body
    assert_match /gsi-material-button/, @response.body
    assert_match /Sign in with Google/, @response.body
  end

  test "can sign out" do
    sign_in @user
    session_record = @user.sessions.last

    delete session_url(session_record)
    assert_redirected_to new_session_path
    assert_equal "You have signed out successfully.", flash[:notice]

    # Verify session is destroyed
    assert_nil Session.find_by(id: session_record.id)
  end

  test "redirects to MFA verification when MFA enabled" do
    @user.setup_mfa!
    @user.enable_mfa!
    @user.sessions.destroy_all # Clean up any existing sessions

    post sessions_path, params: { email: @user.email, password: user_password_test }

    assert_redirected_to verify_mfa_path
    assert_equal @user.id, session[:mfa_user_id]
    assert_not Session.exists?(user_id: @user.id)
  end

  # OIDC Authentication Tests
  test "authenticates with existing OIDC identity" do
    oidc_identity = oidc_identities(:bob_google)

    # Set up OmniAuth mock
    setup_omniauth_mock(
      provider: oidc_identity.provider,
      uid: oidc_identity.uid,
      email: @user.email,
      name: "Bob Dylan",
      first_name: "Bob",
      last_name: "Dylan"
    )

    get "/auth/openid_connect/callback"

    assert_redirected_to root_path
    assert Session.exists?(user_id: @user.id)
  end

  test "redirects to MFA when user has MFA and uses OIDC" do
    @user.setup_mfa!
    @user.enable_mfa!
    @user.sessions.destroy_all
    oidc_identity = oidc_identities(:bob_google)

    # Set up OmniAuth mock
    setup_omniauth_mock(
      provider: oidc_identity.provider,
      uid: oidc_identity.uid,
      email: @user.email,
      name: "Bob Dylan"
    )

    get "/auth/openid_connect/callback"

    assert_redirected_to verify_mfa_path
    assert_equal @user.id, session[:mfa_user_id]
    assert_not Session.exists?(user_id: @user.id)
  end

  test "redirects to account linking when no OIDC identity exists" do
    # Use an existing user's email who doesn't have OIDC linked yet
    user_without_oidc = users(:new_email)

    # Set up OmniAuth mock
    setup_omniauth_mock(
      provider: "openid_connect",
      uid: "new-uid-99999",
      email: user_without_oidc.email,
      name: "New User"
    )

    get "/auth/openid_connect/callback"

    assert_redirected_to link_oidc_account_path

    # Follow redirect to verify session data is accessible
    follow_redirect!
    assert_response :success

    # Verify the session has the pending auth data by checking page content
    assert_select "p", text: /To link your openid_connect account/
  end

  test "handles missing auth data gracefully" do
    # Set up mock with invalid/incomplete auth to simulate failure
    OmniAuth.config.mock_auth[:openid_connect] = OmniAuth::AuthHash.new({
      provider: nil,
      uid: nil
    })

    get "/auth/openid_connect/callback"

    assert_redirected_to new_session_path
    assert_equal "Could not authenticate via OpenID Connect.", flash[:alert]
  end

  # ── Mobile SSO: mobile_sso_start ──

  test "mobile_sso_start renders auto-submit form for valid provider" do
    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "google_oauth2", strategy: "google_oauth2", label: "Google" }
    ])

    get "/auth/mobile/google_oauth2", params: {
      device_id: "test-device-123",
      device_name: "Pixel 8",
      device_type: "android",
      os_version: "14",
      app_version: "1.0.0"
    }

    assert_response :success
    assert_match %r{action="/auth/google_oauth2"}, @response.body
    assert_match %r{method="post"}, @response.body
    assert_match /authenticity_token/, @response.body
  end

  test "mobile_sso_start stores device info in session" do
    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "google_oauth2", strategy: "google_oauth2", label: "Google" }
    ])

    get "/auth/mobile/google_oauth2", params: {
      device_id: "test-device-123",
      device_name: "Pixel 8",
      device_type: "android",
      os_version: "14",
      app_version: "1.0.0"
    }

    assert_equal "test-device-123", session[:mobile_sso][:device_id]
    assert_equal "Pixel 8", session[:mobile_sso][:device_name]
    assert_equal "android", session[:mobile_sso][:device_type]
    assert_equal "14", session[:mobile_sso][:os_version]
    assert_equal "1.0.0", session[:mobile_sso][:app_version]
  end

  test "mobile_sso_start redirects with error for invalid provider" do
    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "google_oauth2", strategy: "google_oauth2", label: "Google" }
    ])

    get "/auth/mobile/unknown_provider", params: {
      device_id: "test-device-123",
      device_name: "Pixel 8",
      device_type: "android"
    }

    assert_redirected_to %r{\Asureapp://oauth/callback\?error=invalid_provider}
  end

  test "mobile_sso_start redirects with error when device_id is missing" do
    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "google_oauth2", strategy: "google_oauth2", label: "Google" }
    ])

    get "/auth/mobile/google_oauth2", params: {
      device_name: "Pixel 8",
      device_type: "android"
    }

    assert_redirected_to %r{\Asureapp://oauth/callback\?error=missing_device_info}
  end

  test "mobile_sso_start redirects with error when device_name is missing" do
    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "google_oauth2", strategy: "google_oauth2", label: "Google" }
    ])

    get "/auth/mobile/google_oauth2", params: {
      device_id: "test-device-123",
      device_type: "android"
    }

    assert_redirected_to %r{\Asureapp://oauth/callback\?error=missing_device_info}
  end

  test "mobile_sso_start redirects with error when device_type is missing" do
    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "google_oauth2", strategy: "google_oauth2", label: "Google" }
    ])

    get "/auth/mobile/google_oauth2", params: {
      device_id: "test-device-123",
      device_name: "Pixel 8"
    }

    assert_redirected_to %r{\Asureapp://oauth/callback\?error=missing_device_info}
  end

  # ── Mobile SSO: openid_connect callback with mobile_sso session ──

  test "mobile SSO issues Doorkeeper tokens for linked user" do
    # Test environment uses null_store; swap in a memory store so the
    # authorization code round-trip (write in controller, read in sso_exchange) works.
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    oidc_identity = oidc_identities(:bob_google)

    setup_omniauth_mock(
      provider: oidc_identity.provider,
      uid: oidc_identity.uid,
      email: @user.email,
      name: "Bob Dylan",
      first_name: "Bob",
      last_name: "Dylan"
    )

    # Simulate mobile_sso session data (would be set by mobile_sso_start)
    post sessions_path, params: { email: @user.email, password: user_password_test }
    delete session_url(@user.sessions.last)

    # We need to set the session directly via a custom approach:
    # Hit mobile_sso_start first, then trigger the OIDC callback
    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "openid_connect", strategy: "openid_connect", label: "Google" }
    ])

    get "/auth/mobile/openid_connect", params: {
      device_id: "flutter-device-001",
      device_name: "Pixel 8",
      device_type: "android",
      os_version: "14",
      app_version: "1.0.0"
    }

    assert_response :success

    # Now trigger the OIDC callback — session[:mobile_sso] is set from the previous request
    get "/auth/openid_connect/callback"

    assert_response :redirect
    redirect_url = @response.redirect_url

    assert redirect_url.start_with?("sureapp://oauth/callback?"), "Expected redirect to sureapp:// but got #{redirect_url}"

    uri = URI.parse(redirect_url)
    callback_params = Rack::Utils.parse_query(uri.query)

    assert callback_params["code"].present?, "Expected authorization code in callback"

    # Exchange the authorization code for tokens via the API (as the mobile app would)
    post "/api/v1/auth/sso_exchange", params: { code: callback_params["code"] }, as: :json

    assert_response :success
    token_data = JSON.parse(@response.body)

    assert token_data["access_token"].present?, "Expected access_token in response"
    assert token_data["refresh_token"].present?, "Expected refresh_token in response"
    assert_equal "Bearer", token_data["token_type"]
    assert_equal 30.days.to_i, token_data["expires_in"]
    assert_equal @user.id, token_data["user"]["id"]
    assert_equal @user.email, token_data["user"]["email"]
    assert_equal @user.first_name, token_data["user"]["first_name"]
    assert_equal @user.last_name, token_data["user"]["last_name"]
  ensure
    Rails.cache = original_cache
  end

  test "mobile SSO creates a MobileDevice record" do
    oidc_identity = oidc_identities(:bob_google)

    setup_omniauth_mock(
      provider: oidc_identity.provider,
      uid: oidc_identity.uid,
      email: @user.email,
      name: "Bob Dylan"
    )

    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "openid_connect", strategy: "openid_connect", label: "Google" }
    ])

    get "/auth/mobile/openid_connect", params: {
      device_id: "flutter-device-002",
      device_name: "iPhone 15",
      device_type: "ios",
      os_version: "17.2",
      app_version: "1.0.0"
    }

    assert_difference "MobileDevice.count", 1 do
      get "/auth/openid_connect/callback"
    end

    device = @user.mobile_devices.find_by(device_id: "flutter-device-002")
    assert device.present?, "Expected MobileDevice to be created"
    assert_equal "iPhone 15", device.device_name
    assert_equal "ios", device.device_type
    assert_equal "17.2", device.os_version
    assert_equal "1.0.0", device.app_version
  end

  test "mobile SSO uses the shared OAuth application" do
    oidc_identity = oidc_identities(:bob_google)

    setup_omniauth_mock(
      provider: oidc_identity.provider,
      uid: oidc_identity.uid,
      email: @user.email,
      name: "Bob Dylan"
    )

    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "openid_connect", strategy: "openid_connect", label: "Google" }
    ])

    get "/auth/mobile/openid_connect", params: {
      device_id: "flutter-device-003",
      device_name: "Pixel 8",
      device_type: "android"
    }

    assert_no_difference "Doorkeeper::Application.count" do
      get "/auth/openid_connect/callback"
    end

    device = @user.mobile_devices.find_by(device_id: "flutter-device-003")
    assert device.active_tokens.any?, "Expected device to have active tokens via shared app"
  end

  test "mobile SSO revokes previous tokens for existing device" do
    oidc_identity = oidc_identities(:bob_google)

    setup_omniauth_mock(
      provider: oidc_identity.provider,
      uid: oidc_identity.uid,
      email: @user.email,
      name: "Bob Dylan"
    )

    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "openid_connect", strategy: "openid_connect", label: "Google" }
    ])

    # First login — creates device and token
    get "/auth/mobile/openid_connect", params: {
      device_id: "flutter-device-004",
      device_name: "Pixel 8",
      device_type: "android"
    }
    get "/auth/openid_connect/callback"

    device = @user.mobile_devices.find_by(device_id: "flutter-device-004")
    first_token = Doorkeeper::AccessToken.where(
      mobile_device_id: device.id,
      resource_owner_id: @user.id,
      revoked_at: nil
    ).last

    assert first_token.present?, "Expected first access token"

    # Second login with same device — should revoke old token
    setup_omniauth_mock(
      provider: oidc_identity.provider,
      uid: oidc_identity.uid,
      email: @user.email,
      name: "Bob Dylan"
    )

    get "/auth/mobile/openid_connect", params: {
      device_id: "flutter-device-004",
      device_name: "Pixel 8",
      device_type: "android"
    }
    get "/auth/openid_connect/callback"

    first_token.reload
    assert first_token.revoked_at.present?, "Expected first token to be revoked"
  end

  test "mobile SSO redirects MFA user with error" do
    @user.setup_mfa!
    @user.enable_mfa!

    oidc_identity = oidc_identities(:bob_google)

    setup_omniauth_mock(
      provider: oidc_identity.provider,
      uid: oidc_identity.uid,
      email: @user.email,
      name: "Bob Dylan"
    )

    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "openid_connect", strategy: "openid_connect", label: "Google" }
    ])

    get "/auth/mobile/openid_connect", params: {
      device_id: "flutter-device-005",
      device_name: "Pixel 8",
      device_type: "android"
    }
    get "/auth/openid_connect/callback"

    assert_response :redirect
    redirect_url = @response.redirect_url

    assert redirect_url.start_with?("sureapp://oauth/callback?"), "Expected redirect to sureapp://"
    params = Rack::Utils.parse_query(URI.parse(redirect_url).query)
    assert_equal "mfa_not_supported", params["error"]
    assert_nil session[:mobile_sso], "Expected mobile_sso session to be cleared"
  end

  test "mobile SSO redirects with error when OIDC identity not linked" do
    user_without_oidc = users(:new_email)

    setup_omniauth_mock(
      provider: "openid_connect",
      uid: "unlinked-uid-99999",
      email: user_without_oidc.email,
      name: "New User"
    )

    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "openid_connect", strategy: "openid_connect", label: "Google" }
    ])

    get "/auth/mobile/openid_connect", params: {
      device_id: "flutter-device-006",
      device_name: "Pixel 8",
      device_type: "android"
    }
    get "/auth/openid_connect/callback"

    assert_response :redirect
    redirect_url = @response.redirect_url

    assert redirect_url.start_with?("sureapp://oauth/callback?"), "Expected redirect to sureapp://"
    params = Rack::Utils.parse_query(URI.parse(redirect_url).query)
    assert_equal "account_not_linked", params["error"]
    assert_nil session[:mobile_sso], "Expected mobile_sso session to be cleared"
  end

  test "mobile SSO does not create a web session" do
    oidc_identity = oidc_identities(:bob_google)

    setup_omniauth_mock(
      provider: oidc_identity.provider,
      uid: oidc_identity.uid,
      email: @user.email,
      name: "Bob Dylan"
    )

    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "openid_connect", strategy: "openid_connect", label: "Google" }
    ])

    @user.sessions.destroy_all

    get "/auth/mobile/openid_connect", params: {
      device_id: "flutter-device-007",
      device_name: "Pixel 8",
      device_type: "android"
    }

    assert_no_difference "Session.count" do
      get "/auth/openid_connect/callback"
    end
  end

  # ── Mobile SSO: failure action ──

  test "failure redirects mobile SSO to app with error" do
    # Simulate mobile_sso session being set
    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "google_oauth2", strategy: "google_oauth2", label: "Google" }
    ])

    get "/auth/mobile/google_oauth2", params: {
      device_id: "flutter-device-008",
      device_name: "Pixel 8",
      device_type: "android"
    }

    # Now simulate a failure callback
    get "/auth/failure", params: { message: "sso_failed", strategy: "google_oauth2" }

    assert_response :redirect
    redirect_url = @response.redirect_url
    assert redirect_url.start_with?("sureapp://oauth/callback?"), "Expected redirect to sureapp://"
    params = Rack::Utils.parse_query(URI.parse(redirect_url).query)
    assert_equal "sso_failed", params["error"]
    assert_nil session[:mobile_sso], "Expected mobile_sso session to be cleared"
  end

  test "failure without mobile SSO session redirects to web login" do
    get "/auth/failure", params: { message: "sso_failed", strategy: "google_oauth2" }

    assert_redirected_to new_session_path
  end

  test "failure sanitizes unknown error reasons" do
    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "google_oauth2", strategy: "google_oauth2", label: "Google" }
    ])

    get "/auth/mobile/google_oauth2", params: {
      device_id: "flutter-device-009",
      device_name: "Pixel 8",
      device_type: "android"
    }

    get "/auth/failure", params: { message: "xss_attempt<script>", strategy: "google_oauth2" }

    redirect_url = @response.redirect_url
    params = Rack::Utils.parse_query(URI.parse(redirect_url).query)
    assert_equal "sso_failed", params["error"], "Unknown reason should be sanitized to sso_failed"
  end

  test "prevents account takeover via email matching" do
    # Clean up any existing sessions
    @user.sessions.destroy_all

    # This test verifies that we can't authenticate just by matching email
    # The user must have an existing OIDC identity with matching provider + uid
    # Set up OmniAuth mock
    setup_omniauth_mock(
      provider: "openid_connect",
      uid: "attacker-uid-12345", # Different UID than user's OIDC identity
      email: @user.email, # Same email as existing user
      name: "Attacker"
    )

    get "/auth/openid_connect/callback"

    # Should NOT create a session, should redirect to account linking
    assert_redirected_to link_oidc_account_path
    assert_not Session.exists?(user_id: @user.id), "Session should not be created for unlinked OIDC identity"

    # Follow redirect to verify we're on the link page (not logged in)
    follow_redirect!
    assert_response :success
  end
end
