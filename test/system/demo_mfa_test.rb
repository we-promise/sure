require "application_system_test_case"

class DemoMfaTest < ApplicationSystemTestCase
  test "demo family cannot start MFA enrollment on a sure.am installation" do
    with_env_overrides("APP_DOMAIN" => "app.sure.am") do
      sign_in users(:empty)
      visit settings_security_path

      assert_text I18n.t("mfa.demo_family_restricted")
      assert_no_link href: new_mfa_path

      visit new_mfa_path
      assert_current_path settings_security_path
      assert_text I18n.t("mfa.demo_family_restricted")
      assert_nil users(:empty).reload.otp_secret
      save_screenshot Rails.root.join("tmp/screenshots/demo-mfa-restricted.png")
    end
  end
end
