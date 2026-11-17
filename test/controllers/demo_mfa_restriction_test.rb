require "test_helper"
require "webauthn/fake_client"

class DemoMfaRestrictionTest < ActionDispatch::IntegrationTest
  setup do
    @demo_user = users(:new_email)
    @member = users(:empty)
    assert_equal Rails.application.config_for(:demo).fetch(:email), @demo_user.email
    assert_equal @demo_user.family, @member.family
  end

  %w[sure.am app.sure.am demo.sure.am nested.demo.sure.am APP.SURE.AM].each do |host|
    test "blocks enrollment for demo family members on #{host}" do
      host! host
      sign_in @member

      get new_mfa_path

      assert_redirected_to settings_security_path
      assert_equal I18n.t("mfa.demo_family_restricted"), flash[:alert]
      assert_nil @member.reload.otp_secret
      assert_not @member.otp_required?
    end
  end

  test "blocks a valid direct enrollment POST with an existing setup secret" do
    host! "app.sure.am"
    sign_in @demo_user
    @demo_user.setup_mfa!
    code = ROTP::TOTP.new(@demo_user.otp_secret).now

    assert_no_difference "SecurityAuditLog.count" do
      post mfa_path, params: { code: code, password: user_password_test }
    end

    assert_redirected_to settings_security_path
    assert_not @demo_user.reload.otp_required?
    assert_empty @demo_user.otp_backup_codes
  end

  test "deployment domain also protects enrollment through an alternate hostname" do
    with_env_overrides("APP_DOMAIN" => "app.sure.am") do
      host! "service.onrender.com"
      sign_in @member
      get new_mfa_path
      assert_redirected_to settings_security_path
      assert_nil @member.reload.otp_secret
    end
  end

  %w[finance.example.com notsure.am sure.am.example.com sure-demo.pikapod.net].each do |host|
    test "allows the demo family to enroll outside sure.am on #{host}" do
      with_env_overrides("APP_DOMAIN" => nil) do
        host! host
        sign_in @member
        get new_mfa_path
        assert_response :success
        code = ROTP::TOTP.new(@member.reload.otp_secret).now
        post mfa_path, params: { code: code, password: user_password_test }
        assert_response :success
        assert @member.reload.otp_required?
      end
    end
  end

  test "allows another family to enroll on sure.am even with the demo family name" do
    user = users(:family_admin)
    user.family.update!(name: @demo_user.family.name)
    host! "app.sure.am"
    sign_in user
    get new_mfa_path
    assert_response :success
    code = ROTP::TOTP.new(user.reload.otp_secret).now
    post mfa_path, params: { code: code, password: user_password_test }
    assert_response :success
    assert user.reload.otp_required?
  end

  test "blocks passkey options for a demo member with existing MFA" do
    host! "app.sure.am"
    sign_in @member
    @member.setup_mfa!
    @member.enable_mfa!

    post options_settings_webauthn_credentials_path,
      params: { webauthn_credential: { code: ROTP::TOTP.new(@member.otp_secret).now } }, as: :json

    assert_response :forbidden
    assert_equal I18n.t("mfa.demo_family_restricted"), response.parsed_body["error"]
    assert_nil @member.reload.webauthn_id
  end

  test "blocks passkey creation even with a previously issued valid challenge" do
    host! "app.sure.am"
    sign_in @member
    @member.setup_mfa!
    @member.enable_mfa!
    # Obtain a real challenge before this family becomes the configured demo.
    @demo_user.update!(email: "former-demo@example.com")
    code = ROTP::TOTP.new(@member.otp_secret).now
    post options_settings_webauthn_credentials_path,
      params: { webauthn_credential: { code: code } }, as: :json
    assert_response :success
    client = WebAuthn::FakeClient.new("http://app.sure.am")
    credential = client.create(challenge: response.parsed_body.fetch("challenge"), rp_id: "app.sure.am")
    @demo_user.update!(email: Rails.application.config_for(:demo).fetch(:email))

    assert_no_difference "WebauthnCredential.count" do
      post settings_webauthn_credentials_path,
        params: { credential: credential, webauthn_credential: { nickname: "Demo key", code: code } }, as: :json
    end
    assert_response :forbidden
    assert_equal I18n.t("mfa.demo_family_restricted"), response.parsed_body["error"]
  end

  test "hides enrollment controls but keeps MFA and passkey removal available" do
    host! "app.sure.am"
    sign_in @member
    get settings_security_path
    assert_response :success
    assert_select "a[href=?]", new_mfa_path, count: 0
    assert_includes response.body, I18n.t("mfa.demo_family_restricted")

    @member.setup_mfa!
    @member.enable_mfa!
    credential = @member.webauthn_credentials.create!(nickname: "Old key", credential_id: "old-demo-key", public_key: "key")
    get settings_security_path
    assert_response :success
    assert_select "form[action=?]", settings_webauthn_credentials_path, count: 0
    assert_select "form[action=?]", disable_mfa_path, count: 1

    delete settings_webauthn_credential_path(credential)
    assert_redirected_to settings_security_path
    assert_not WebauthnCredential.exists?(credential.id)
    delete disable_mfa_path, params: { password: user_password_test }
    assert_redirected_to settings_security_path
    assert_not @member.reload.otp_required?
  end
end
