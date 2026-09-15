require "test_helper"
require "webauthn/fake_client"

class Settings::WebauthnCredentialsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.webauthn_credentials.destroy_all
    sign_in @user
    @user.setup_mfa!
    @user.enable_mfa!
    @client = WebAuthn::FakeClient.new("http://www.example.com")
  end

  test "options require enabled MFA" do
    @user.disable_mfa!

    post options_settings_webauthn_credentials_path, as: :json

    assert_response :forbidden
    assert_equal I18n.t("webauthn_credentials.mfa_required"), JSON.parse(response.body).fetch("error")
  end

  test "asks for a discoverable credential so it can be used for passwordless sign-in" do
    options = registration_options

    assert_equal "preferred", options.dig("authenticatorSelection", "residentKey")
    assert_equal "preferred", options.dig("authenticatorSelection", "userVerification")
  end

  test "creates a credential from a verified registration challenge" do
    options = registration_options
    credential = @client.create(challenge: options.fetch("challenge"), rp_id: "www.example.com")

    assert_difference -> { @user.webauthn_credentials.count }, 1 do
      post settings_webauthn_credentials_path, params: {
        webauthn_credential: { nickname: "MacBook Touch ID" },
        credential: credential
      }, as: :json
    end

    assert_response :success
    assert_equal settings_security_path, JSON.parse(response.body).fetch("redirect_url")

    stored_credential = @user.webauthn_credentials.reload.last
    assert_equal "MacBook Touch ID", stored_credential.nickname
    assert_equal credential.fetch("id"), stored_credential.credential_id
    assert_includes stored_credential.transports, "internal"
    assert @user.reload.webauthn_id.present?
  end

  test "creating a credential writes an audit log entry" do
    options = registration_options
    credential = @client.create(challenge: options.fetch("challenge"), rp_id: "www.example.com")

    assert_difference "SecurityAuditLog.count", 1 do
      post settings_webauthn_credentials_path, params: {
        webauthn_credential: { nickname: "MacBook Touch ID" },
        credential: credential
      }, as: :json
    end

    log = SecurityAuditLog.last
    stored_credential = @user.webauthn_credentials.reload.last
    assert_equal "webauthn_credential_added", log.event_type
    assert_equal stored_credential.id, log.metadata["credential_id"]
    assert_equal "MacBook Touch ID", log.metadata["nickname"]
  end

  test "does not persist the credential when the audit log write fails" do
    options = registration_options
    credential = @client.create(challenge: options.fetch("challenge"), rp_id: "www.example.com")
    SecurityAuditLog.stubs(:log_webauthn_credential_added!).raises(ActiveRecord::RecordInvalid.new(SecurityAuditLog.new))

    assert_no_difference -> { @user.webauthn_credentials.count } do
      post settings_webauthn_credentials_path, params: {
        webauthn_credential: { nickname: "MacBook Touch ID" },
        credential: credential
      }, as: :json
    end

    assert_response :unprocessable_entity
  end

  test "does not destroy the credential when the audit log write fails" do
    credential = @user.webauthn_credentials.create!(
      nickname: "YubiKey",
      credential_id: "credential-audit-fail",
      public_key: "public-key"
    )
    SecurityAuditLog.stubs(:log_webauthn_credential_removed!).raises(ActiveRecord::RecordInvalid.new(SecurityAuditLog.new))

    assert_no_difference -> { @user.webauthn_credentials.count } do
      delete settings_webauthn_credential_path(credential)
    end

    assert_redirected_to settings_security_path
  end

  test "a rejected registration does not write an audit log" do
    registration_options

    assert_no_difference "SecurityAuditLog.count" do
      post settings_webauthn_credentials_path, params: {
        webauthn_credential: { nickname: "Malformed" },
        credential: []
      }, as: :json
    end
  end

  test "uses configured relying party id and allowed origin" do
    with_webauthn_config(rp_id: "example.test", allowed_origins: [ "https://app.example.test" ]) do
      client = WebAuthn::FakeClient.new("https://app.example.test")
      options = registration_options

      assert_equal "example.test", options.dig("rp", "id")

      credential = client.create(challenge: options.fetch("challenge"), rp_id: "example.test")

      assert_difference -> { @user.webauthn_credentials.count }, 1 do
        post settings_webauthn_credentials_path, params: {
          webauthn_credential: { nickname: "Configured origin key" },
          credential: credential
        }, as: :json
      end

      assert_response :success
    end
  end

  test "rejects a credential when registration challenge has already been used" do
    options = registration_options
    credential = @client.create(challenge: options.fetch("challenge"), rp_id: "www.example.com")

    post settings_webauthn_credentials_path, params: {
      webauthn_credential: { nickname: "MacBook Touch ID" },
      credential: credential
    }, as: :json
    assert_response :success

    assert_no_difference -> { @user.webauthn_credentials.count } do
      post settings_webauthn_credentials_path, params: {
        webauthn_credential: { nickname: "Replay" },
        credential: credential
      }, as: :json
    end

    assert_response :unprocessable_entity
  end

  test "rejects malformed credential payloads" do
    registration_options

    assert_no_difference -> { @user.webauthn_credentials.count } do
      post settings_webauthn_credentials_path, params: {
        webauthn_credential: { nickname: "Malformed" },
        credential: []
      }, as: :json
    end

    assert_response :unprocessable_entity
    assert_equal I18n.t("webauthn_credentials.failure"), JSON.parse(response.body).fetch("error")
  end

  test "rejects database-level duplicate credential races" do
    registration_options
    @user.webauthn_credentials.create!(
      nickname: "Existing security key",
      credential_id: "duplicate-credential-id",
      public_key: "public-key"
    )

    verified_credential = Struct.new(:id, :public_key, :sign_count).new("duplicate-credential-id", "new-public-key", 0)
    relying_party = mock("webauthn_relying_party")
    relying_party.expects(:verify_registration).returns(verified_credential)
    Settings::WebauthnCredentialsController.any_instance.stubs(:webauthn_relying_party).returns(relying_party)

    assert_no_difference -> { @user.webauthn_credentials.count } do
      post settings_webauthn_credentials_path, params: {
        webauthn_credential: { nickname: "Duplicate security key" },
        credential: { id: "duplicate-credential-id", response: {} }
      }, as: :json
    end

    assert_response :unprocessable_entity
    assert_equal I18n.t("webauthn_credentials.failure"), JSON.parse(response.body).fetch("error")
  end

  test "uses localized default credential nickname" do
    options = registration_options
    credential = @client.create(challenge: options.fetch("challenge"), rp_id: "www.example.com")

    post settings_webauthn_credentials_path, params: {
      webauthn_credential: { nickname: "" },
      credential: credential
    }, as: :json

    assert_response :success
    assert_equal I18n.t("webauthn_credentials.default_name"), @user.webauthn_credentials.reload.last.nickname
  end

  test "destroys a credential owned by the current user" do
    credential = @user.webauthn_credentials.create!(
      nickname: "YubiKey",
      credential_id: "credential-to-delete",
      public_key: "public-key"
    )

    assert_difference -> { @user.webauthn_credentials.count }, -1 do
      delete settings_webauthn_credential_path(credential)
    end

    assert_redirected_to settings_security_path

    log = SecurityAuditLog.where(user: @user, event_type: "webauthn_credential_removed").last
    assert_equal credential.id, log.metadata["credential_id"]
    assert_equal "YubiKey", log.metadata["nickname"]
  end

  private
    def registration_options
      post options_settings_webauthn_credentials_path, as: :json
      assert_response :success
      JSON.parse(response.body)
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
