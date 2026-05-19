require "test_helper"

class Settings::SecuritiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.webauthn_credentials.destroy_all
  end

  test "shows passkey guidance before MFA is enabled" do
    @user.disable_mfa!

    get settings_security_url

    assert_response :success
    assert_includes response.body, "Passkeys and security keys"
    assert_includes response.body, "Enable 2FA before adding passkeys"
    assert_select "[data-controller='webauthn-registration']", count: 0
    assert_select "a[href='#{new_mfa_path}']", text: "Enable 2FA"
  end

  test "shows passkey registration form after MFA is enabled" do
    @user.setup_mfa!
    @user.enable_mfa!

    get settings_security_url

    assert_response :success
    assert_includes response.body, "Add passkey or security key"
    assert_select "[data-controller='webauthn-registration']"
  end
end
