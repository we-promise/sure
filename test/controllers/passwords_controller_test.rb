require "test_helper"

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "update changes the password when it meets the sign-up rules" do
    patch password_path, params: { user: {
      password_challenge: user_password_test,
      password: "NewSecure1!",
      password_confirmation: "NewSecure1!"
    } }

    assert_redirected_to root_url
    assert @user.reload.authenticate("NewSecure1!")
  end

  test "update rejects a password that only meets the minimum length" do
    patch password_path, params: { user: {
      password_challenge: user_password_test,
      password: "password",
      password_confirmation: "password"
    } }

    assert_response :unprocessable_entity
    assert_not @user.reload.authenticate("password")
    assert_select "p.text-destructive", text: /uppercase and lowercase/
  end

  test "update names each missing character type" do
    patch password_path, params: { user: {
      password_challenge: user_password_test,
      password: "Abcdefgh",
      password_confirmation: "Abcdefgh"
    } }

    assert_response :unprocessable_entity
    assert_not @user.reload.authenticate("Abcdefgh")
    assert_select "p.text-destructive", text: /at least one number/
    assert_select "p.text-destructive", text: /at least one special character/
  end

  test "update rejects a blank new password instead of reporting success" do
    patch password_path, params: { user: {
      password_challenge: user_password_test,
      password: "",
      password_confirmation: ""
    } }

    assert_response :unprocessable_entity
    assert @user.reload.authenticate(user_password_test)
    assert_select "p.text-destructive", text: /can't be blank/
  end
end
