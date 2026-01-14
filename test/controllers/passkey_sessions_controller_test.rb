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

  test "options returns webauthn get options for discoverable credentials" do
    get options_passkey_session_path

    assert_response :success
    json = JSON.parse(response.body)

    assert json["challenge"].present?
    # For discoverable credentials, allowCredentials should be empty or not present
    assert json["allowCredentials"].blank?
  end

  test "options stores challenge in session" do
    get options_passkey_session_path

    assert_response :success
    assert session[:passkey_authentication_challenge].present?
  end

  test "create returns error with invalid credential format" do
    # First get options to set up the session
    get options_passkey_session_path
    assert_response :success

    # Try to authenticate with invalid credential
    post passkey_session_path, params: { credential: { invalid: "data" } }, as: :json

    assert_response :unprocessable_entity
  end

  test "create returns error when passkey not found" do
    # First get options to set up the session
    get options_passkey_session_path
    assert_response :success

    # Try to authenticate with a credential that doesn't exist
    post passkey_session_path, params: {
      credential: {
        id: "nonexistent-credential-id",
        type: "public-key",
        rawId: Base64.urlsafe_encode64("nonexistent-credential-id", padding: false),
        response: {
          clientDataJSON: Base64.urlsafe_encode64("{}", padding: false),
          authenticatorData: Base64.urlsafe_encode64("auth-data", padding: false),
          signature: Base64.urlsafe_encode64("signature", padding: false),
          userHandle: nil
        }
      }
    }, as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json["error"].present?
  end

  test "does not require authentication" do
    # These endpoints should be accessible without authentication
    get new_passkey_session_path
    assert_response :success

    get options_passkey_session_path
    assert_response :success
  end
end
