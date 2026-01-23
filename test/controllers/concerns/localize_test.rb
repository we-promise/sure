require "test_helper"

class LocalizeTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
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
end
