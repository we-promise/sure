require "test_helper"

class LocalizeTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @original_locale = @family.locale
    @family.update!(locale: "en")
  end

  teardown do
    @family.update!(locale: @original_locale || "en")
  end

  test "uses family locale by default" do
    get preferences_onboarding_url
    assert_response :success
    assert_select "h1", text: /Configure your preferences/i
  end

  test "switches locale when locale param is provided" do
    get preferences_onboarding_url(locale: "fr")
    assert_response :success
    assert_select "h1", text: /Configurez vos préférences/i
  end

  test "ignores invalid locale param and uses family locale" do
    get preferences_onboarding_url(locale: "invalid_locale")
    assert_response :success
    assert_select "h1", text: /Configure your preferences/i
  end

  test "falls back to default locale when family has no locale and param is invalid" do
    @family.update_column(:locale, nil)
    get preferences_onboarding_url(locale: "invalid")
    assert_response :success
    # Falls back to I18n.default_locale (en)
    assert_select "h1", text: /Configure your preferences/i
  end
end
