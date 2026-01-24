require "test_helper"

class LocalizeTest < ActionDispatch::IntegrationTest
  test "uses Accept-Language top locale on login when supported" do
    get new_session_url, headers: { "Accept-Language" => "fr-CA,fr;q=0.9" }
    assert_response :success
    assert_select "button", text: /Se connecter/i
  end

  test "falls back to English when Accept-Language is unsupported" do
    get new_session_url, headers: { "Accept-Language" => "ru-RU,ru;q=0.9" }
    assert_response :success
    assert_select "button", text: /Log in/i
  end

  test "uses family locale by default" do
    sign_in users(:family_admin)

    get preferences_onboarding_url
    assert_response :success
    assert_select "h1", text: /Configure your preferences/i
  end

  test "keeps family locale even when Accept-Language differs" do
    sign_in users(:family_admin)

    get preferences_onboarding_url, headers: { "Accept-Language" => "es-ES,es;q=0.9" }
    assert_response :success
    assert_select "h1", text: /Configure your preferences/i
  end

  test "switches locale when locale param is provided" do
    sign_in users(:family_admin)

    get preferences_onboarding_url(locale: "fr")
    assert_response :success
    assert_select "h1", text: /Configurez vos préférences/i
  end

  test "ignores invalid locale param and uses family locale" do
    sign_in users(:family_admin)

    get preferences_onboarding_url(locale: "invalid_locale")
    assert_response :success
    assert_select "h1", text: /Configure your preferences/i
  end
end
