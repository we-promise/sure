require "test_helper"

class Settings::SecuritiesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  test "shows encryption warning when self-hosted and encryption is not configured" do
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    ActiveRecordEncryptionConfig.stubs(:ready?).returns(false)

    get settings_security_url

    assert_response :success
    assert_includes response.body, I18n.t("settings.securities.show.encryption_warning.title")
  end

  test "hides encryption warning when encryption is configured" do
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    ActiveRecordEncryptionConfig.stubs(:ready?).returns(true)

    get settings_security_url

    assert_response :success
    assert_not_includes response.body, I18n.t("settings.securities.show.encryption_warning.title")
  end

  test "hides encryption warning when only runtime-generated keys are available" do
    # Regression test for issue #3142: self-hosted installs relying on the
    # SECRET_KEY_BASE auto-generation fallback (explicitly_configured? false,
    # runtime_configured? true) must NOT see the "not configured" warning.
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    ActiveRecordEncryptionConfig.stubs(:runtime_configured?).returns(true)

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

  test "warns when encryption keys are auto-derived from a known compromised secret" do
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    ActiveRecordEncryptionConfig.stubs(:ready?).returns(true)
    ActiveRecordEncryptionConfig.stubs(:using_known_compromised_secret_key_base?).returns(true)

    get settings_security_url

    assert_response :success
    assert_includes response.body, I18n.t("settings.securities.show.compromised_secret_warning.title")
  end

  test "hides compromised secret warning when encryption is not configured at all" do
    # The "not configured" warning takes priority; don't show both.
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    ActiveRecordEncryptionConfig.stubs(:ready?).returns(false)
    ActiveRecordEncryptionConfig.stubs(:using_known_compromised_secret_key_base?).returns(true)

    get settings_security_url

    assert_response :success
    assert_not_includes response.body, I18n.t("settings.securities.show.compromised_secret_warning.title")
  end

  test "hides compromised secret warning when keys are not derived from the known value" do
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    ActiveRecordEncryptionConfig.stubs(:ready?).returns(true)
    ActiveRecordEncryptionConfig.stubs(:using_known_compromised_secret_key_base?).returns(false)

    get settings_security_url

    assert_response :success
    assert_not_includes response.body, I18n.t("settings.securities.show.compromised_secret_warning.title")
  end

  test "does not show compromised secret warning in managed mode" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    ActiveRecordEncryptionConfig.stubs(:using_known_compromised_secret_key_base?).returns(true)

    get settings_security_url

    assert_response :success
    assert_not_includes response.body, I18n.t("settings.securities.show.compromised_secret_warning.title")
  end
end
