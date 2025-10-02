require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
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

  test "can sign up with openid connect" do
    OmniAuth.config.test_mode = true

    auth_hash = OmniAuth::AuthHash.new(
      provider: "openid_connect",
      uid: "oidc-123",
      info: OmniAuth::AuthHash.new(
        email: "jane.doe.oidc@example.com",
        first_name: "Jane",
        last_name: "Doe",
        name: "Jane Doe"
      )
    )

    Rails.application.env_config["omniauth.auth"] = auth_hash
    Rails.application.env_config["omniauth.params"] = { "flow" => "signup" }

    assert_difference -> { Family.count }, 1 do
      assert_difference -> { User.count }, 1 do
        assert_difference -> { Session.count }, 1 do
          post "/auth/openid_connect/callback"
        end
      end
    end

    assert_redirected_to preferences_onboarding_url

    user = User.find_by(email: "jane.doe.oidc@example.com")
    assert_not_nil user
    assert_equal "Jane", user.first_name
    assert_equal "Doe", user.last_name
    assert_equal "Doe", user.family.name
    assert_equal "US", user.family.country
    assert_equal "en", user.family.locale
    assert_equal "USD", user.family.currency
    assert_equal "%Y-%m-%d", user.family.date_format
    assert user.sessions.exists?

    get onboarding_url
    assert_redirected_to preferences_onboarding_url
  ensure
    Rails.application.env_config.delete("omniauth.auth")
    Rails.application.env_config.delete("omniauth.params")
    OmniAuth.config.mock_auth[:openid_connect] = nil if OmniAuth.config.respond_to?(:mock_auth)
    OmniAuth.config.test_mode = false
  end
end
