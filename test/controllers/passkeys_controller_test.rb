require "test_helper"

class PasskeysControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @passkey = passkeys(:bob_passkey)
  end

  test "new returns webauthn creation options" do
    sign_in @user

    get new_passkey_path

    assert_response :success
    json = JSON.parse(response.body)

    assert json["challenge"].present?
    assert json["rp"].present?
    assert json["user"].present?
    assert_equal @user.email, json["user"]["name"]
  end

  test "new requires authentication" do
    get new_passkey_path
    assert_redirected_to new_session_path
  end

  test "create requires authentication" do
    post passkeys_path, params: { credential: {} }
    assert_redirected_to new_session_path
  end

  test "create with invalid credential returns error" do
    sign_in @user

    # Set up a challenge in session
    get new_passkey_path
    assert_response :success

    # Try to create with invalid credential data
    post passkeys_path, params: { credential: { invalid: "data" } }, as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal false, json["success"]
  end

  test "destroy removes passkey" do
    sign_in @user

    assert_difference "Passkey.count", -1 do
      delete passkey_path(@passkey)
    end

    assert_redirected_to settings_security_path
    assert_equal I18n.t("passkeys.destroy.success"), flash[:notice]
  end

  test "destroy requires authentication" do
    delete passkey_path(@passkey)
    assert_redirected_to new_session_path
  end

  test "cannot destroy another user's passkey" do
    sign_in users(:family_member)

    assert_no_difference "Passkey.count" do
      delete passkey_path(@passkey)
    end

    assert_response :not_found
  end
end
