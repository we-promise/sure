require "application_system_test_case"

class SettingsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    @settings_links = [
      [ "Accounts", accounts_path ],
      [ "Bank Sync", settings_bank_sync_path ],
      [ "Preferences", settings_preferences_path ],
      [ "Profile Info", settings_profile_path ],
      [ "Security", settings_security_path ],
      [ "Categories", categories_path ],
      [ "Tags", tags_path ],
      [ "Rules", rules_path ],
      [ "Merchants", family_merchants_path ],
      [ "AI Prompts", settings_ai_prompts_path ],
      [ "API Key", settings_api_key_path ],
      [ "Imports", imports_path ],
      [ "SimpleFin", simplefin_items_path ],
      [ "Guides", settings_guides_path ],
      [ "What's new", changelog_path ],
      [ "Feedback", feedback_path ]
    ]
  end

  test "can access settings from sidebar" do
    VCR.use_cassette("git_repository_provider/fetch_latest_release_notes") do
      open_settings_from_sidebar
      assert_selector "h1", text: "Accounts"
      assert_current_path accounts_path, ignore_query: true

      @settings_links.each do |name, path|
        click_link name
        assert_selector "h1", text: name
        assert_current_path path
      end
    end
  end

  test "can update self hosting settings" do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    Provider::Registry.stubs(:get_provider).with(:twelve_data).returns(nil)
    open_settings_from_sidebar
    assert_selector "li", text: "Self-Hosting"
    click_link "Self-Hosting"
    assert_current_path settings_hosting_path
    assert_selector "h1", text: "Self-Hosting"
    check "setting[require_invite_for_signup]", allow_label_click: true
    click_button "Generate new code"
    assert_selector 'span[data-clipboard-target="source"]', visible: true, count: 1 # invite code copy widget
    copy_button = find('button[data-action="clipboard#copy"]', match: :first) # Find the first copy button (adjust if needed)
    copy_button.click
    assert_selector 'span[data-clipboard-target="iconSuccess"]', visible: true, count: 1 # text copied and icon changed to checkmark
  end

  test "does not show billing link if self hosting" do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    open_settings_from_sidebar
    assert_no_selector "li", text: I18n.t("settings.settings_nav.billing_label")
  end

  test "can delete export from UI" do
    # Create a test export
    export = @user.family.family_exports.create!(status: "completed")
    export.export_file.attach(
      io: StringIO.new("test content"),
      filename: "test_export.zip",
      content_type: "application/zip"
    )

    # Navigate to imports page (which shows exports)
    visit imports_path
    assert_selector "h1", text: "Exports"

    # Verify the export is displayed
    assert_selector "p", text: export.filename

    # Find and click the delete button (trash icon)
    delete_button = find('button[data-turbo-confirm*="delete this export"]')
    assert_not_nil delete_button, "Delete button should be present"

    # Click delete and confirm
    delete_button.click
    accept_confirm

    # Should be redirected back to imports page
    assert_current_path imports_path

    # Export should be removed from the list
    assert_no_selector "p", text: export.filename
  end

  private

    def open_settings_from_sidebar
      within "div[data-testid=user-menu]" do
        find("button").click
      end
      click_link "Settings"
    end
end
