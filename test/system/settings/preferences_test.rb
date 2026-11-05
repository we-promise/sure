require "application_system_test_case"

class Settings::PreferencesTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.family.update!(timezone: "America/New_York")
  end

  test "picks a time zone in the searchable select and keeps it after reload" do
    visit settings_preferences_path

    trigger = find("button#timezone_trigger")
    container = trigger.ancestor("div.relative", match: :first)
    trigger.click
    container.find("input[type='search']", visible: true).set("Moscow")
    container.find("[role='listbox'] [role='option'][data-value='Europe/Moscow']", visible: true).click

    assert_text "(+03:00) Europe/Moscow"
    # The form auto-submits; wait for the save before reloading the page.
    page.document.synchronize do
      raise Capybara::ExpectationNotMet unless @user.family.reload.timezone == "Europe/Moscow"
    end

    visit settings_preferences_path
    assert_selector "button#timezone_trigger", text: "(+03:00) Europe/Moscow"
  end
end
