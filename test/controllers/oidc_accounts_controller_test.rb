require "test_helper"

class OidcAccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
  end

  def pending_auth
    {
      "provider" => "openid_connect",
      "uid" => "new-uid-12345",
      "email" => @user.email,
      "name" => "Bob Dylan",
      "first_name" => "Bob",
      "last_name" => "Dylan"
    }
  end

  def set_pending_auth(auth_data)
    # Set session data by making a request that stores it
    post sessions_path, env: {
      "rack.session" => { pending_oidc_auth: auth_data }
    }, params: {}
  end

  test "should show link page when pending auth exists" do
    # Simulate OmniAuth callback via the sessions controller
    get "/auth/openid_connect/callback", env: {
      "omniauth.auth" => OmniAuth::AuthHash.new({
        provider: pending_auth["provider"],
        uid: pending_auth["uid"],
        info: {
          email: pending_auth["email"],
          name: pending_auth["name"]
        }
      }),
      "rack.session" => {},
      "action_dispatch.show_exceptions" => :none
    }

    get link_oidc_account_path
    assert_response :success
  end

  test "should redirect to login when no pending auth" do
    get link_oidc_account_path
    assert_redirected_to new_session_path
    assert_equal "No pending OIDC authentication found", flash[:alert]
  end

  test "should create OIDC identity with valid password" do
    assert_difference "OidcIdentity.count", 1 do
      post create_link_oidc_account_path,
        params: {
          email: @user.email,
          password: user_password_test
        },
        session: { pending_oidc_auth: pending_auth }
    end

    assert_redirected_to root_path
    assert_not_nil @user.oidc_identities.find_by(
      provider: pending_auth["provider"],
      uid: pending_auth["uid"]
    )
  end

  test "should reject linking with invalid password" do
    assert_no_difference "OidcIdentity.count" do
      post create_link_oidc_account_path,
        params: {
          email: @user.email,
          password: "wrongpassword"
        },
        session: { pending_oidc_auth: pending_auth }
    end

    assert_response :unprocessable_entity
    assert_equal "Invalid email or password", flash[:alert]
  end

  test "should redirect to MFA when user has MFA enabled" do
    @user.setup_mfa!
    @user.enable_mfa!

    post create_link_oidc_account_path,
      params: {
        email: @user.email,
        password: user_password_test
      },
      session: { pending_oidc_auth: pending_auth }

    assert_redirected_to verify_mfa_path
  end

  test "should reject create_link when no pending auth" do
    post create_link_oidc_account_path, params: {
      email: @user.email,
      password: user_password_test
    }

    assert_redirected_to new_session_path
    assert_equal "No pending OIDC authentication found", flash[:alert]
  end

  # New user registration tests
  def new_user_auth
    {
      "provider" => "openid_connect",
      "uid" => "new-uid-99999",
      "email" => "newuser@example.com",
      "name" => "New User",
      "first_name" => "New",
      "last_name" => "User"
    }
  end

  test "should show create account option for new user" do
    get link_oidc_account_path, session: { pending_oidc_auth: new_user_auth }
    assert_response :success
    assert_select "h3", text: "Create New Account"
    assert_select "strong", text: new_user_auth["email"]
  end

  test "should create new user account via OIDC" do
    assert_difference ["User.count", "OidcIdentity.count", "Family.count"], 1 do
      post create_user_oidc_account_path, session: { pending_oidc_auth: new_user_auth }
    end

    assert_redirected_to root_path
    assert_equal "Welcome! Your account has been created.", flash[:notice]

    # Verify user was created with correct details
    new_user = User.find_by(email: new_user_auth["email"])
    assert_not_nil new_user
    assert_equal new_user_auth["first_name"], new_user.first_name
    assert_equal new_user_auth["last_name"], new_user.last_name
    assert_equal "admin", new_user.role

    # Verify OIDC identity was created
    oidc_identity = new_user.oidc_identities.first
    assert_not_nil oidc_identity
    assert_equal new_user_auth["provider"], oidc_identity.provider
    assert_equal new_user_auth["uid"], oidc_identity.uid
  end

  test "should create session after OIDC registration" do
    post create_user_oidc_account_path, session: { pending_oidc_auth: new_user_auth }

    # Verify session was created
    new_user = User.find_by(email: new_user_auth["email"])
    assert Session.exists?(user_id: new_user.id)
  end

  test "should reject create_user when no pending auth" do
    post create_user_oidc_account_path

    assert_redirected_to new_session_path
    assert_equal "No pending OIDC authentication found", flash[:alert]
  end
end
