require "test_helper"

class PasskeysControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @passkey = passkeys(:bob_passkey)
  end

  # --- New action tests ---

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

  test "new returns options with discoverable credential settings" do
    sign_in @user

    get new_passkey_path

    assert_response :success
    json = JSON.parse(response.body)

    # Should have authenticator selection for resident keys
    assert json["authenticatorSelection"].present?
    assert_equal "preferred", json["authenticatorSelection"]["residentKey"]
    assert_equal "preferred", json["authenticatorSelection"]["userVerification"]
  end

  test "new excludes existing passkeys" do
    sign_in @user

    get new_passkey_path

    assert_response :success
    json = JSON.parse(response.body)

    # Should have exclude credentials for existing passkeys
    assert json["excludeCredentials"].present?
    assert_equal @user.passkeys.count, json["excludeCredentials"].length
  end

  test "new requires authentication" do
    get new_passkey_path
    assert_redirected_to new_session_path
  end

  # --- Create action tests ---

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

  test "create with missing credential id returns error" do
    sign_in @user

    # Set up a challenge in session
    get new_passkey_path
    assert_response :success

    # Try to create with missing id
    post passkeys_path, params: { credential: { type: "public-key" } }, as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal false, json["success"]
    assert_equal "Invalid credential data", json["error"]
  end

  # --- Update action tests ---

  test "update renames passkey via html" do
    sign_in @user

    patch passkey_path(@passkey), params: { label: "New Passkey Name" }

    assert_redirected_to settings_security_path
    assert_equal I18n.t("passkeys.update.success"), flash[:notice]
    @passkey.reload
    assert_equal "New Passkey Name", @passkey.label
  end

  test "update renames passkey via json" do
    sign_in @user

    patch passkey_path(@passkey), params: { label: "New Passkey Name" }, as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["success"]
    assert_equal "New Passkey Name", json["passkey"]["label"]
    @passkey.reload
    assert_equal "New Passkey Name", @passkey.label
  end

  test "update requires authentication" do
    patch passkey_path(@passkey), params: { label: "New Name" }
    assert_redirected_to new_session_path
  end

  test "cannot update another user's passkey" do
    sign_in users(:family_member)

    patch passkey_path(@passkey), params: { label: "Hacked Name" }

    assert_response :not_found
    @passkey.reload
    assert_equal "Bob's MacBook", @passkey.label
  end

  # --- Destroy action tests ---

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
