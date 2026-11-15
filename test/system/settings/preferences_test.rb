require "application_system_test_case"

class Settings::PreferencesTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.family.update!(timezone: "America/New_York")
  end

  test "finds a time zone by its identifier, saves it and keeps it after reload" do
    visit settings_preferences_path

    trigger = find("button#timezone_trigger")
    container = trigger.ancestor("div.relative", match: :first)
    trigger.click
    container.find("input[type='search']", visible: true).set("Asia/Ho_Chi")
    container.find("[role='listbox'] [role='option'][data-value='Asia/Ho_Chi_Minh']", visible: true).click

    assert_text "(+07:00) Asia/Ho Chi Minh"
    # The form auto-submits; wait for the save before reloading the page.
    page.document.synchronize do
      raise Capybara::ExpectationNotMet unless @user.family.reload.timezone == "Asia/Ho_Chi_Minh"
    end

    visit settings_preferences_path
    assert_selector "button#timezone_trigger", text: "(+07:00) Asia/Ho Chi Minh"
  end
end
