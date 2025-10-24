require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
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
