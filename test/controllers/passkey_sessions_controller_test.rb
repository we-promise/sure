require "test_helper"

class PasskeySessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @passkey = passkeys(:bob_passkey)
  end

  test "new renders passkey authentication page" do
    get new_passkey_session_path

    assert_response :success
  end

  test "new accepts email parameter" do
    get new_passkey_session_path, params: { email: @user.email }

    assert_response :success
  end

  test "options returns error for user without passkeys" do
    user_without_passkeys = users(:family_member)

    get options_passkey_session_path, params: { email: user_without_passkeys.email }

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json["error"].present?
  end

  test "options returns error for unknown email" do
    get options_passkey_session_path, params: { email: "unknown@example.com" }

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json["error"].present?
  end

  test "options returns webauthn get options for user with passkeys" do
    get options_passkey_session_path, params: { email: @user.email }

    assert_response :success
    json = JSON.parse(response.body)

    assert json["challenge"].present?
    assert json["allowCredentials"].present?
  end

  test "create returns error without valid session" do
    post passkey_session_path, params: { credential: {} }, as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json["error"].present?
  end

  test "create returns error with invalid credential" do
    # First get options to set up the session
    get options_passkey_session_path, params: { email: @user.email }
    assert_response :success

    # Try to authenticate with invalid credential
    post passkey_session_path, params: { credential: { invalid: "data" } }, as: :json

    assert_response :unprocessable_entity
  end

  test "does not require authentication" do
    # These endpoints should be accessible without authentication
    get new_passkey_session_path
    assert_response :success

    get options_passkey_session_path, params: { email: @user.email }
    assert_response :success
  end
end
