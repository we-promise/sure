require "test_helper"
require "webauthn/fake_client"

class PasskeySessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.webauthn_credentials.destroy_all
    sign_in @user
    @user.setup_mfa!
    @user.enable_mfa!
    @client = register_webauthn_credential
    @stored_credential = @user.webauthn_credentials.reload.first
    sign_out
  end

  test "signs in with a discoverable passkey, skipping password and TOTP" do
    assertion = passkey_assertion

    post passkey_session_path, params: { credential: assertion }, as: :json

    assert_response :success
    assert_equal root_path, JSON.parse(response.body).fetch("redirect_url")
    assert Session.exists?(user_id: @user.id)
    assert @stored_credential.reload.last_used_at.present?
    assert_operator @stored_credential.sign_count, :>, 0
  end

  test "rejects passkey authentication when session creation fails" do
    PasskeySessionsController.any_instance.stubs(:create_session_for).returns(false)

    post passkey_session_path, params: { credential: passkey_assertion }, as: :json

    assert_response :unprocessable_entity
    assert_equal I18n.t("passkey_sessions.invalid_credential"), JSON.parse(response.body).fetch("error")
    assert_not Session.exists?(user_id: @user.id)
  end

  # The pending invitation lives in the Rack session, and complete_sign_in reads
  # it immediately after creating the session. Anything that clears the session
  # in between — a reset_session added to "fix" session fixation, say — drops the
  # invitee into their own family with no error and no failing test.
  test "accepts a pending invitation stored before the passkey sign-in" do
    invitation = Invitation.create!(
      email: @user.email,
      role: "member",
      family: @user.family,
      inviter: @user
    )

    get new_session_path(invitation: invitation.token)
    assert_response :success

    post passkey_session_path, params: { credential: passkey_assertion }, as: :json

    assert_response :success
    assert invitation.reload.accepted_at.present?, "invitation was not accepted during passkey sign-in"
    assert_equal "member", @user.reload.role
  end

  test "rejects an assertion without user verification" do
    assertion = passkey_assertion(user_verified: false)

    post passkey_session_path, params: { credential: assertion }, as: :json

    assert_response :unprocessable_entity
    assert_equal I18n.t("passkey_sessions.invalid_credential"), JSON.parse(response.body).fetch("error")
    assert_not Session.exists?(user_id: @user.id)
  end

  test "rejects an unknown user handle" do
    assertion = passkey_assertion(user_handle: WebAuthn.generate_user_id)

    post passkey_session_path, params: { credential: assertion }, as: :json

    assert_response :unprocessable_entity
    assert_not Session.exists?(user_id: @user.id)
  end

  # A blank handle must not fall through to `find_by(webauthn_id: nil)`, which
  # would match every user who never registered a credential.
  test "rejects a blank user handle" do
    other_user = users(:family_member)
    assert_nil other_user.webauthn_id

    assertion = passkey_assertion
    assertion["response"]["userHandle"] = nil

    post passkey_session_path, params: { credential: assertion }, as: :json

    assert_response :unprocessable_entity
    assert_empty Session.where(user_id: [ @user.id, other_user.id ])
  end

  test "rejects a credential that belongs to a different user than the handle" do
    other_user = users(:family_member)
    other_user.ensure_webauthn_id!

    assertion = passkey_assertion(user_handle: other_user.reload.webauthn_id)

    post passkey_session_path, params: { credential: assertion }, as: :json

    assert_response :unprocessable_entity
    assert_empty Session.where(user_id: [ @user.id, other_user.id ])
  end

  test "rejects a deactivated user" do
    @user.update_column(:active, false)
    assertion = passkey_assertion

    post passkey_session_path, params: { credential: assertion }, as: :json

    assert_response :unprocessable_entity
    assert_not Session.exists?(user_id: @user.id)
  end

  test "rejects a replayed assertion" do
    assertion = passkey_assertion

    post passkey_session_path, params: { credential: assertion }, as: :json
    assert_response :success

    Session.where(user_id: @user.id).destroy_all

    post passkey_session_path, params: { credential: assertion }, as: :json

    assert_response :unprocessable_entity
    assert_not Session.exists?(user_id: @user.id)
  end

  test "rejects an assertion with no challenge in the session" do
    assertion = passkey_assertion

    reset!

    post passkey_session_path, params: { credential: assertion }, as: :json

    assert_response :unprocessable_entity
    assert_not Session.exists?(user_id: @user.id)
  end

  test "rejects malformed credential payloads" do
    post passkey_session_options_path, as: :json
    assert_response :success

    post passkey_session_path, params: { credential: "not-json" }, as: :json

    assert_response :unprocessable_entity
    assert_not Session.exists?(user_id: @user.id)
  end

  test "rejects users who are not allowed to use local login" do
    AuthConfig.stubs(:local_login_allowed_for?).returns(false)
    assertion = passkey_assertion

    post passkey_session_path, params: { credential: assertion }, as: :json

    assert_response :unprocessable_entity
    assert_not Session.exists?(user_id: @user.id)
  end

  test "both endpoints are unavailable when passkey login is disabled" do
    AuthConfig.stubs(:passkey_login_enabled?).returns(false)

    post passkey_session_options_path, as: :json
    assert_response :forbidden

    post passkey_session_path, params: { credential: {} }, as: :json
    assert_response :forbidden
    assert_not Session.exists?(user_id: @user.id)
  end

  test "requests a discoverable credential with user verification required" do
    post passkey_session_options_path, as: :json

    assert_response :success
    options = JSON.parse(response.body)
    assert_equal "www.example.com", options.fetch("rpId")
    assert_equal "required", options.fetch("userVerification")
    assert_empty options.fetch("allowCredentials")
  end

  test "options use the configured relying party id" do
    with_webauthn_config(rp_id: "example.test", allowed_origins: [ "https://app.example.test" ]) do
      post passkey_session_options_path, as: :json

      assert_response :success
      assert_equal "example.test", JSON.parse(response.body).fetch("rpId")
    end
  end

  private
    # Runs a full options -> get -> assertion cycle against the passwordless
    # endpoint, so each assertion is bound to a freshly minted challenge.
    def passkey_assertion(user_verified: true, user_handle: nil)
      post passkey_session_options_path, as: :json
      assert_response :success
      options = JSON.parse(response.body)

      @client.get(
        challenge: options.fetch("challenge"),
        rp_id: "www.example.com",
        user_verified: user_verified,
        user_handle: raw_user_handle(user_handle || @user.reload.webauthn_id)
      )
    end

    # FakeClient encodes whatever it is handed, but `webauthn_id` is already a
    # base64url string, so it has to be decoded back to raw bytes first.
    def raw_user_handle(webauthn_id)
      WebAuthn.standard_encoder.decode(webauthn_id)
    end

    def register_webauthn_credential(origin: "http://www.example.com", rp_id: "www.example.com")
      client = WebAuthn::FakeClient.new(origin)

      post options_settings_webauthn_credentials_path, as: :json
      options = JSON.parse(response.body)
      credential = client.create(challenge: options.fetch("challenge"), rp_id: rp_id)
      post settings_webauthn_credentials_path, params: {
        webauthn_credential: { nickname: "MacBook Touch ID" },
        credential: credential
      }, as: :json
      assert_response :success

      client
    end

    def sign_out
      # Deleting sessions through the controller de-authenticates the request the
      # moment our own session dies, so every later delete in the loop is a
      # silent no-op and whichever sessions sort after it survive. The order is
      # unspecified, which made every suite that signs out this way flaky.
      # Teardown hygiene is not the behavior under test, so destroy directly.
      @user.sessions.destroy_all
    end

    def with_webauthn_config(rp_id:, allowed_origins:)
      config = Rails.application.config.x.webauthn
      previous_rp_id = config.rp_id
      previous_allowed_origins = config.allowed_origins
      config.rp_id = rp_id
      config.allowed_origins = allowed_origins

      yield
    ensure
      config.rp_id = previous_rp_id
      config.allowed_origins = previous_allowed_origins
    end
end
