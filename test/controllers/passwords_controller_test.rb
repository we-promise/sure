require "test_helper"

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other_session = @user.sessions.create!
    sign_in @user
  end

  test "changing the password revokes every other session and keeps the current one" do
    patch password_path, params: { user: {
      password: "NewPassw0rd!",
      password_confirmation: "NewPassw0rd!",
      password_challenge: user_password_test
    } }

    assert_redirected_to root_path
    assert_not Session.exists?(@other_session.id)
    assert Session.exists?(Current.session.id)
  end

  test "a rejected password change leaves every session in place" do
    patch password_path, params: { user: {
      password: "short",
      password_confirmation: "mismatch",
      password_challenge: user_password_test
    } }

    assert_response :unprocessable_entity
    assert Session.exists?(@other_session.id)
  end
end
