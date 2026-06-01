require "application_system_test_case"

class Settings::ApiKeysTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.api_keys.destroy_all # Ensure clean state
    login_as @user
  end

  test "should show empty state when user has no API keys" do
    visit settings_api_keys_path

    assert_text "API Keys"
    assert_text "No API keys yet"
    assert_link "New API Key", href: new_settings_api_key_path
  end

  test "should create multiple keys, list them, and revoke one" do
    # Create the first key
    visit settings_api_keys_path
    click_link "New API Key"

    assert_current_path new_settings_api_key_path
    assert_text "Create New API Key"

    fill_in "API Key Name", with: "First Key"
    choose "Read/Write"
    click_button "Save API Key"

    # Newly-created confirmation page shows the plain key
    assert_text "API Key Created Successfully"
    assert_text "First Key"
    api_key_display = find("[data-clipboard-target='source']")
    assert api_key_display.text.length > 30 # Should be a long hex string

    # Back to the list, the first key is shown
    click_link "Continue to API Key Settings"
    assert_current_path settings_api_keys_path
    assert_text "First Key"

    # Create a SECOND key with a different name
    click_link "New API Key"
    fill_in "API Key Name", with: "Second Key"
    choose "Read Only"
    click_button "Save API Key"

    assert_text "API Key Created Successfully"
    click_link "Continue to API Key Settings"

    # Both keys appear in the list
    assert_current_path settings_api_keys_path
    assert_text "First Key"
    assert_text "Second Key"

    # Revoke the first key via the custom confirmation dialog
    within all(".bg-container", text: "First Key").first do
      click_button "Revoke"
    end

    assert_selector "#confirm-dialog", visible: true
    within "#confirm-dialog" do
      click_button "Confirm"
    end
    assert_no_selector "#confirm-dialog"

    # First key gone, second remains
    assert_no_text "First Key"
    assert_text "Second Key"

    assert @user.api_keys.where(name: "First Key").first.revoked?
    refute @user.api_keys.active.where(name: "Second Key").empty?
  end

  test "should show API keys in navigation" do
    visit settings_api_keys_path

    within("nav") do
      assert_text "API Keys"
    end
  end
end
