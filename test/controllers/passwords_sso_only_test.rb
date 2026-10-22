require "test_helper"

class PasswordsSsoOnlyTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
  end

  test "edit and update work when local login is enabled" do
    sign_in @user

    get edit_password_path
    assert_response :ok

    patch password_path, params: { user: { password_challenge: user_password_test, password: "NewPassword1!", password_confirmation: "NewPassword1!" } }
    assert_redirected_to root_path
    assert @user.reload.authenticate("NewPassword1!")
  end

  test "edit and update redirect when only SSO is allowed" do
    sign_in @user
    AuthConfig.stubs(:local_login_enabled?).returns(false)
    AuthConfig.stubs(:local_admin_override_enabled?).returns(false)

    get edit_password_path
    assert_redirected_to root_path
    assert_equal "Changing your password in Sure is disabled. Please manage your password through your identity provider.", flash[:alert]

    assert_no_changes -> { @user.reload.password_digest } do
      patch password_path, params: { user: { password_challenge: user_password_test, password: "NewPassword1!", password_confirmation: "NewPassword1!" } }
    end
    assert_redirected_to root_path
    assert_equal "Changing your password in Sure is disabled. Please manage your password through your identity provider.", flash[:alert]
  end

  test "regular users stay blocked when the local admin override is enabled" do
    sign_in @user
    AuthConfig.stubs(:local_login_enabled?).returns(false)
    AuthConfig.stubs(:local_admin_override_enabled?).returns(true)

    get edit_password_path
    assert_redirected_to root_path

    assert_no_changes -> { @user.reload.password_digest } do
      patch password_path, params: { user: { password_challenge: user_password_test, password: "NewPassword1!", password_confirmation: "NewPassword1!" } }
    end
    assert_redirected_to root_path
  end

  test "super admins can change their password under the local admin override" do
    super_admin = users(:sure_support_staff)
    sign_in super_admin
    AuthConfig.stubs(:local_login_enabled?).returns(false)
    AuthConfig.stubs(:local_admin_override_enabled?).returns(true)

    get edit_password_path
    assert_response :ok

    patch password_path, params: { user: { password_challenge: user_password_test, password: "NewPassword1!", password_confirmation: "NewPassword1!" } }
    assert_redirected_to root_path
    assert super_admin.reload.authenticate("NewPassword1!")
  end
end
