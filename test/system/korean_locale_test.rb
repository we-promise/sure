require "application_system_test_case"

class KoreanLocaleTest < ApplicationSystemTestCase
  test "a Korean user sees localized navigation and document language" do
    user = users(:family_admin)
    user.update!(locale: "ko")

    sign_in user

    assert_selector "html[lang=ko]"
    assert_link "거래 내역", href: transactions_path
    visit settings_preferences_path
    assert_text "환경설정"
    assert_text "한국어 (ko)"
    FileUtils.mkdir_p(Rails.root.join("tmp/screenshots"))
    page.save_screenshot(Rails.root.join("tmp/screenshots/korean-preferences.png"))
  end
end
