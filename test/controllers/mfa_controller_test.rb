require "test_helper"
require "webauthn/fake_client"

class MfaControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_member)
    sign_in @user
  end

  def sign_out
    @user.sessions.each do |session|
      delete session_path(session)
    end
  end

  test "redirects to root if MFA already enabled" do
    @user.setup_mfa!
    @user.enable_mfa!

    get new_mfa_path
    assert_redirected_to root_path
  end

  test "sets up MFA when visiting new" do
    get new_mfa_path

    assert_response :success
    assert @user.reload.otp_secret.present?
    assert_not @user.otp_required?
    assert_select "svg" # QR code should be present
  end

  test "enables MFA with valid code" do
    @user.setup_mfa!
    totp = ROTP::TOTP.new(@user.otp_secret, issuer: "Sure Finances")

    post mfa_path, params: { code: totp.now }

    assert_response :success
    assert @user.reload.otp_required?
    assert_equal 8, @user.otp_backup_codes.length
    assert @user.otp_backup_codes.all? { |code| code.start_with?("$2") }
    assert_select "div.grid-cols-2" # Check for backup codes grid
    rendered_codes = css_select("div.grid-cols-2 div").map { |node| node.text.strip }
    assert_equal 8, rendered_codes.length
    assert rendered_codes.all? { |code| code.match?(/\A[0-9a-f]{16}\z/) }
    assert_empty rendered_codes & @user.otp_backup_codes
  end

  test "does not enable MFA with invalid code" do
    @user.setup_mfa!

    post mfa_path, params: { code: "invalid" }

    assert_redirected_to new_mfa_path
    assert_not @user.reload.otp_required?
    assert_empty @user.otp_backup_codes
  end

  test "verify shows MFA verification page" do
    @user.setup_mfa!
    @user.enable_mfa!
    sign_out

    post sessions_path, params: { email: @user.email, password: user_password_test }
    assert_redirected_to verify_mfa_path

    get verify_mfa_path
    assert_response :success
    assert_select "form[action=?]", verify_mfa_path
  end

  test "verify shows WebAuthn option when credentials are registered" do
    @user.setup_mfa!
    @user.enable_mfa!
    register_webauthn_credential
    sign_out

    post sessions_path, params: { email: @user.email, password: user_password_test }
    get verify_mfa_path

    assert_response :success
    assert_select "button", text: I18n.t("mfa.verify.webauthn_button")
    assert_select "[data-webauthn-authentication-error-fallback-value=?]", I18n.t("mfa.verify_webauthn.invalid_credential")
    assert_select "p[data-webauthn-authentication-target='error'][aria-live='assertive'][aria-atomic='true'][aria-hidden='true']"
  end

  test "verify_code authenticates with valid TOTP" do
    @user.setup_mfa!
    @user.enable_mfa!
    sign_out

    post sessions_path, params: { email: @user.email, password: user_password_test }
    totp = ROTP::TOTP.new(@user.otp_secret, issuer: "Sure Finances")

    post verify_mfa_path, params: { code: totp.now }

    assert_redirected_to root_path
    assert Session.exists?(user_id: @user.id)
  end

  test "verify_code authenticates with valid backup code" do
    @user.setup_mfa!
    backup_code = @user.enable_mfa!.first
    matching_digest = @user.otp_backup_codes.find { |digest| BCrypt::Password.new(digest).is_password?(backup_code) }
    assert_not_nil matching_digest
    sign_out

    post sessions_path, params: { email: @user.email, password: user_password_test }

    post verify_mfa_path, params: { code: backup_code }

    assert_redirected_to root_path
    assert Session.exists?(user_id: @user.id)
    assert_equal 7, @user.reload.otp_backup_codes.size
    assert_not_includes @user.otp_backup_codes, matching_digest
  end

  test "verify_code rejects invalid codes" do
    @user.setup_mfa!
    @user.enable_mfa!
    sign_out

    post sessions_path, params: { email: @user.email, password: user_password_test }
    post verify_mfa_path, params: { code: "invalid" }

    assert_response :unprocessable_entity
    assert_not Session.exists?(user_id: @user.id)
  end

  test "webauthn_options require a pending MFA session" do
    post webauthn_options_mfa_path, as: :json

    assert_response :unprocessable_entity
  end

  test "verify_webauthn authenticates with a registered credential" do
    @user.setup_mfa!
    @user.enable_mfa!
    client = register_webauthn_credential
    stored_credential = @user.webauthn_credentials.first
    sign_out

    post sessions_path, params: { email: @user.email, password: user_password_test }
    post webauthn_options_mfa_path, as: :json
    assert_response :success

    options = JSON.parse(response.body)
    assertion = client.get(
      challenge: options.fetch("challenge"),
      rp_id: "www.example.com",
      allow_credentials: [ stored_credential.credential_id ]
    )

    post verify_webauthn_mfa_path, params: { credential: assertion }, as: :json

    assert_response :success
    assert_equal root_path, JSON.parse(response.body).fetch("redirect_url")
    assert Session.exists?(user_id: @user.id)
    assert stored_credential.reload.last_used_at.present?
    assert_operator stored_credential.sign_count, :>, 0
  end

  test "verify_webauthn authenticates with configured relying party id" do
    with_webauthn_config(rp_id: "example.test", allowed_origins: [ "https://app.example.test" ]) do
      @user.setup_mfa!
      @user.enable_mfa!
      client = register_webauthn_credential(origin: "https://app.example.test", rp_id: "example.test")
      stored_credential = @user.webauthn_credentials.first
      sign_out

      post sessions_path, params: { email: @user.email, password: user_password_test }
      post webauthn_options_mfa_path, as: :json
      assert_response :success

      options = JSON.parse(response.body)
      assert_equal "example.test", options.fetch("rpId")
      assertion = client.get(
        challenge: options.fetch("challenge"),
        rp_id: "example.test",
        allow_credentials: [ stored_credential.credential_id ]
      )

      post verify_webauthn_mfa_path, params: { credential: assertion }, as: :json

      assert_response :success
      assert_equal root_path, JSON.parse(response.body).fetch("redirect_url")
    end
  end

  test "verify_webauthn rejects invalid credentials" do
    @user.setup_mfa!
    @user.enable_mfa!
    client = register_webauthn_credential
    stored_credential = @user.webauthn_credentials.first
    sign_out

    post sessions_path, params: { email: @user.email, password: user_password_test }
    post webauthn_options_mfa_path, as: :json
    options = JSON.parse(response.body)
    assertion = client.get(
      challenge: options.fetch("challenge"),
      rp_id: "www.example.com",
      allow_credentials: [ stored_credential.credential_id ]
    )
    assertion["id"] = "invalid"

    post verify_webauthn_mfa_path, params: { credential: assertion }, as: :json

    assert_response :unprocessable_entity
    assert_not Session.exists?(user_id: @user.id)
  end

  test "verify_webauthn rejects malformed credential payloads" do
    @user.setup_mfa!
    @user.enable_mfa!
    register_webauthn_credential
    sign_out

    post sessions_path, params: { email: @user.email, password: user_password_test }
    post webauthn_options_mfa_path, as: :json
    assert_response :success

    post verify_webauthn_mfa_path, params: { credential: [] }, as: :json

    assert_response :unprocessable_entity
    assert_equal I18n.t("mfa.verify_webauthn.invalid_credential"), JSON.parse(response.body).fetch("error")
    assert_not Session.exists?(user_id: @user.id)
  end

  test "disable removes MFA" do
    @user.setup_mfa!
    @user.enable_mfa!
    @user.webauthn_credentials.create!(
      nickname: "YubiKey",
      credential_id: "disable-mfa-credential",
      public_key: "public-key"
    )

    delete disable_mfa_path

    assert_redirected_to settings_security_path
    assert_not @user.reload.otp_required?
    assert_nil @user.otp_secret
    assert_empty @user.otp_backup_codes
    assert_empty @user.webauthn_credentials
  end

  private
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
