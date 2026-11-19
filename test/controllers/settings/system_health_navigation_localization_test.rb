require "test_helper"

class Settings::SystemHealthNavigationLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
  end

  test "German system health navigation has a translation without fallback" do
    assert_equal "Systemstatus", I18n.t("settings.settings_nav.system_health_label", locale: :de, fallback: false, raise: true)
  end

  test "super admins see localized system health links in both navigation layouts" do
    user = users(:sure_support_staff)
    sign_in user

    { "de" => "Systemstatus", "en" => "System health" }.each do |locale, label|
      user.update!(locale: locale)
      get settings_preferences_url

      assert_response :success
      assert_select "nav a[href='#{admin_system_health_path}']", text: label, count: 2
    end
  end

  test "German system health navigation remains hidden from other roles" do
    %i[family_admin family_member].each do |fixture|
      user = users(fixture)
      user.update!(locale: "de")
      sign_in user
      get settings_preferences_url

      assert_response :success
      assert_select "nav a[href='#{admin_system_health_path}']", count: 0
    end
  end
end
