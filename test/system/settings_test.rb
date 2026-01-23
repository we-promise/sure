require "application_system_test_case"

class SettingsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    # Base settings available to all users
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
      [ "Guides", settings_guides_path ],
      [ "What's new", changelog_path ],
      [ "Feedback", feedback_path ]
    ]

    # Add admin settings if user is admin
    if @user.admin?
      @settings_links += [
        [ "AI Prompts", settings_ai_prompts_path ],
        [ "API Key", settings_api_key_path ]
      ]
    end
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
    Provider::Registry.stubs(:get_provider).with(:yahoo_finance).returns(nil)
    open_settings_from_sidebar
    assert_selector "li", text: "Self-Hosting"
    click_link "Self-Hosting"
    assert_current_path settings_hosting_path
    assert_selector "h1", text: "Self-Hosting"
    find("select#setting_onboarding_state").select("Invite-only")
    within("select#setting_onboarding_state") do
      assert_selector "option[selected]", text: "Invite-only"
    end
    click_button "Generate new code"
    assert_selector 'span[data-clipboard-target="source"]', visible: true, count: 1 # invite code copy widget
    copy_button = find('button[data-action="clipboard#copy"]', match: :first) # Find the first copy button (adjust if needed)
    copy_button.click
    assert_selector 'span[data-clipboard-target="iconSuccess"]', visible: true, count: 1 # text copied and icon changed to checkmark
  end

  test "does not show payment link if self hosting" do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    open_settings_from_sidebar
    assert_no_selector "li", text: I18n.t("settings.settings_nav.payment_label")
  end

  test "does not show admin settings to non-admin users" do
    VCR.use_cassette("git_repository_provider/fetch_latest_release_notes") do
      # Visit accounts path directly as non-admin user to avoid user menu issues
      visit new_session_path
      within %(form[action='#{sessions_path}']) do
        fill_in "Email", with: users(:family_member).email
        fill_in "Password", with: user_password_test
        click_on "Log in"
      end

      # Go directly to accounts (settings) page
      visit accounts_path

      # Assert that admin-only settings are not present in the navigation
      assert_no_selector "li", text: "AI Prompts"
      assert_no_selector "li", text: "API Key"
    end
  end

  private

    def open_settings_from_sidebar
      within "div[data-testid=user-menu]" do
        find("button").click
      end
      click_link "Settings"
    end
end
