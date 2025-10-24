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

  test "should show create account option for new user" do
    session[:pending_oidc_auth] = new_user_auth

    get :link
    assert_response :success
    assert_select "h3", text: "Create New Account"
    assert_select "strong", text: new_user_auth["email"]
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
    assert_equal "admin", new_user.role

    # Verify OIDC identity was created
    oidc_identity = new_user.oidc_identities.first
    assert_not_nil oidc_identity
    assert_equal new_user_auth["provider"], oidc_identity.provider
    assert_equal new_user_auth["uid"], oidc_identity.uid
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
end
