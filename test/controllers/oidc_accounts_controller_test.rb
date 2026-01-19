require "test_helper"

class OidcAccountsControllerTest < ActionController::TestCase
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

  test "should show link page when pending auth exists" do
    session[:pending_oidc_auth] = pending_auth
    get :link
    assert_response :success
  end

  test "should redirect to login when no pending auth" do
    get :link
    assert_redirected_to new_session_path
    assert_equal "No pending OIDC authentication found", flash[:alert]
  end

  test "should create OIDC identity with valid password" do
    session[:pending_oidc_auth] = pending_auth

    assert_difference "OidcIdentity.count", 1 do
      post :create_link,
        params: {
          email: @user.email,
          password: user_password_test
        }
    end

    assert_redirected_to root_path
    assert_not_nil @user.oidc_identities.find_by(
      provider: pending_auth["provider"],
      uid: pending_auth["uid"]
    )
  end

  test "should reject linking with invalid password" do
    session[:pending_oidc_auth] = pending_auth

    assert_no_difference "OidcIdentity.count" do
      post :create_link,
        params: {
          email: @user.email,
          password: "wrongpassword"
        }
    end

    assert_response :unprocessable_entity
    assert_equal "Invalid email or password", flash[:alert]
  end

  test "should redirect to MFA when user has MFA enabled" do
    @user.setup_mfa!
    @user.enable_mfa!

    session[:pending_oidc_auth] = pending_auth

    post :create_link,
      params: {
        email: @user.email,
        password: user_password_test
      }

    assert_redirected_to verify_mfa_path
  end

  test "should reject create_link when no pending auth" do
    post :create_link, params: {
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

  test "should show new_user page when pending auth exists" do
    session[:pending_oidc_auth] = new_user_auth
    get :new_user
    assert_response :success
  end

  test "should redirect new_user to login when no pending auth" do
    get :new_user
    assert_redirected_to new_session_path
    assert_equal "No pending OIDC authentication found", flash[:alert]
  end

  test "should show create account option for new user" do
    session[:pending_oidc_auth] = new_user_auth

    get :link
    assert_response :success
    assert_select "h3", text: "Create New Account"
    assert_select "strong", text: new_user_auth["email"]
  end

  test "does not show create account button when JIT link-only mode" do
    session[:pending_oidc_auth] = new_user_auth

    AuthConfig.stubs(:jit_link_only?).returns(true)
    AuthConfig.stubs(:allowed_oidc_domain?).returns(true)

    get :link
    assert_response :success

    assert_select "h3", text: "Create New Account"
    # No create account button rendered
    assert_select "button", text: "Create Account", count: 0
    assert_select "p", text: /New account creation via single sign-on is disabled/
  end

  test "create_user redirects when JIT link-only mode" do
    session[:pending_oidc_auth] = new_user_auth

    AuthConfig.stubs(:jit_link_only?).returns(true)
    AuthConfig.stubs(:allowed_oidc_domain?).returns(true)

    assert_no_difference [ "User.count", "OidcIdentity.count", "Family.count" ] do
      post :create_user
    end

    assert_redirected_to new_session_path
    assert_equal "SSO account creation is disabled. Please contact an administrator.", flash[:alert]
  end

  test "create_user redirects when email domain not allowed" do
    disallowed_auth = new_user_auth.merge("email" => "newuser@notallowed.com")
    session[:pending_oidc_auth] = disallowed_auth

    AuthConfig.stubs(:jit_link_only?).returns(false)
    AuthConfig.stubs(:allowed_oidc_domain?).with(disallowed_auth["email"]).returns(false)

    assert_no_difference [ "User.count", "OidcIdentity.count", "Family.count" ] do
      post :create_user
    end

    assert_redirected_to new_session_path
    assert_equal "SSO account creation is disabled. Please contact an administrator.", flash[:alert]
  end

  test "should create new user account via OIDC" do
    session[:pending_oidc_auth] = new_user_auth

    assert_difference [ "User.count", "OidcIdentity.count", "Family.count" ], 1 do
      post :create_user
    end

    assert_redirected_to root_path
    assert_equal "Welcome! Your account has been created.", flash[:notice]

    # Verify user was created with correct details
    new_user = User.find_by(email: new_user_auth["email"])
    assert_not_nil new_user
    assert_equal new_user_auth["first_name"], new_user.first_name
    assert_equal new_user_auth["last_name"], new_user.last_name
    assert_equal "admin", new_user.role  # Family creators should be admin

    # Verify OIDC identity was created
    oidc_identity = new_user.oidc_identities.first
    assert_not_nil oidc_identity
    assert_equal new_user_auth["provider"], oidc_identity.provider
    assert_equal new_user_auth["uid"], oidc_identity.uid
  end

  test "create_user uses form params for name when provided" do
    session[:pending_oidc_auth] = new_user_auth

    assert_difference [ "User.count", "OidcIdentity.count" ], 1 do
      post :create_user, params: {
        user: { first_name: "Custom", last_name: "Name" }
      }
    end

    assert_redirected_to root_path

    new_user = User.find_by(email: new_user_auth["email"])
    assert_equal "Custom", new_user.first_name
    assert_equal "Name", new_user.last_name
  end

  test "create_user falls back to OIDC data when form params are blank" do
    session[:pending_oidc_auth] = new_user_auth

    post :create_user, params: {
      user: { first_name: "", last_name: "" }
    }

    new_user = User.find_by(email: new_user_auth["email"])
    assert_equal new_user_auth["first_name"], new_user.first_name
    assert_equal new_user_auth["last_name"], new_user.last_name
  end

  test "should create session after OIDC registration" do
    session[:pending_oidc_auth] = new_user_auth

    post :create_user

    # Verify session was created
    new_user = User.find_by(email: new_user_auth["email"])
    assert Session.exists?(user_id: new_user.id)
  end

  test "should reject create_user when no pending auth" do
    post :create_user

    assert_redirected_to new_session_path
    assert_equal "No pending OIDC authentication found", flash[:alert]
  end

  # Security: JIT users should NOT have password_digest set
  test "JIT user is created without password_digest to prevent chained auth attacks" do
    session[:pending_oidc_auth] = new_user_auth

    post :create_user

    new_user = User.find_by(email: new_user_auth["email"])
    assert_not_nil new_user, "User should be created"
    assert_nil new_user.password_digest, "JIT user should have nil password_digest"
    assert new_user.sso_only?, "JIT user should be SSO-only"
  end

  test "JIT user cannot authenticate with local password" do
    session[:pending_oidc_auth] = new_user_auth

    post :create_user

    new_user = User.find_by(email: new_user_auth["email"])

    # Attempting to authenticate should return nil (no password set)
    assert_nil User.authenticate_by(
      email: new_user.email,
      password: "anypassword"
    ), "SSO-only user should not authenticate with password"
  end
end
