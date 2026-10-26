require "test_helper"

class Settings::SecuritiesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  test "shows encryption warning when self-hosted and encryption is not configured" do
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)

    get settings_security_url

    assert_response :success
    assert_includes response.body, I18n.t("settings.securities.show.encryption_warning.title")
  end

  test "hides encryption warning when encryption is configured" do
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)

    get settings_security_url

    assert_response :success
    assert_not_includes response.body, I18n.t("settings.securities.show.encryption_warning.title")
  end

  test "does not show encryption warning in managed mode" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)

    get settings_security_url

    assert_response :success
    assert_not_includes response.body, I18n.t("settings.securities.show.encryption_warning.title")
  end

  test "the disable-MFA control asks for the password" do
    user = users(:family_admin)
    user.setup_mfa!
    user.enable_mfa!

    get settings_security_url

    assert_response :success
    assert_select "form[action=?][method=?]", disable_mfa_path, "post" do
      assert_select "input[type=password][name=?]", "password"
    end
  end

  test "a user without a local password is told MFA lives with their provider" do
    identity = oidc_identities(:sso_only_identity)
    OmniAuth.config.mock_auth[:openid_connect] = OmniAuth::AuthHash.new(
      provider: identity.provider,
      uid: identity.uid,
      info: { email: identity.user.email, name: identity.user.display_name },
      credentials: {}
    )
    get "/auth/openid_connect/callback"

    get settings_security_url

    assert_response :success
    assert_includes response.body, I18n.t("settings.securities.show.mfa_sso_only")
    assert_select "a[href=?]", new_mfa_path, count: 0
  ensure
    OmniAuth.config.mock_auth[:openid_connect] = nil
  end
end
