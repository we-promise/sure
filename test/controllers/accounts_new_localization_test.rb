require "test_helper"

class AccountsNewLocalizationTest < ActiveSupport::TestCase
  TRANSLATIONS = {
    "previous" => "Zurück",
    "next" => "Weiter"
  }.freeze

  test "German account container keyboard labels resolve without fallback" do
    TRANSLATIONS.each do |key, expected|
      full_key = "accounts.new.container.#{key}"

      assert I18n.exists?(full_key, :de, fallback: false), "de is missing #{full_key}"
      assert_equal expected, I18n.t(full_key, locale: :de, fallback: false)
    end
  end
end

class AccountsNewLocalizationRenderTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
  end

  test "German account creation renders localized keyboard controls" do
    @user.update!(locale: "de")

    get new_account_url

    assert_response :success
    assert_select "button[data-action='list-keyboard-navigation#focusPrevious']", text: "Zurück", count: 1
    assert_select "button[data-action='list-keyboard-navigation#focusNext']", text: "Weiter", count: 1
    assert_no_match(/>Previous</, response.body)
    assert_no_match(/>Next</, response.body)
  end

  test "English account creation preserves the keyboard controls" do
    @user.update!(locale: "en")

    get new_account_url

    assert_response :success
    assert_select "button[data-action='list-keyboard-navigation#focusPrevious']", text: "Previous", count: 1
    assert_select "button[data-action='list-keyboard-navigation#focusNext']", text: "Next", count: 1
  end
end
