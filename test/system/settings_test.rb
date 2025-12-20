require "application_system_test_case"

class SettingsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    # Base settings available to all users
    @settings_links = [
      [ I18n.t("settings.settings_nav.accounts_label"), accounts_path ],
      [ I18n.t("settings.settings_nav.bank_sync_label"), settings_bank_sync_path ],
      [ I18n.t("settings.settings_nav.preferences_label"), settings_preferences_path ],
      [ I18n.t("settings.settings_nav.profile_label"), settings_profile_path ],
      [ I18n.t("settings.settings_nav.security_label"), settings_security_path ],
      [ I18n.t("settings.settings_nav.categories_label"), categories_path ],
      [ I18n.t("settings.settings_nav.tags_label"), tags_path ],
      [ I18n.t("settings.settings_nav.rules_label"), rules_path ],
      [ I18n.t("settings.settings_nav.merchants_label"), family_merchants_path ],
      [ I18n.t("settings.settings_nav.guides_label"), settings_guides_path ],
      [ I18n.t("settings.settings_nav.whats_new_label"), changelog_path ],
      [ I18n.t("settings.settings_nav.feedback_label"), feedback_path ]
    ]

    # Add admin settings if user is admin
    if @user.admin?
      @settings_links += [
        [ I18n.t("settings.settings_nav.ai_prompts_label"), settings_ai_prompts_path ],
        [ I18n.t("settings.settings_nav.api_keys_label"), settings_api_key_path ]
      ]
    end
  end

  test "can access settings from sidebar" do
    VCR.use_cassette("git_repository_provider/fetch_latest_release_notes") do
      open_settings_from_sidebar
      assert_selector "h1", text: I18n.t("accounts.index.accounts")
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
    assert_selector "li", text: I18n.t("settings.settings_nav.self_hosting_label")
    click_link I18n.t("settings.settings_nav.self_hosting_label")
    assert_current_path settings_hosting_path
    assert_selector "h1", text: I18n.t("settings.hostings.show.title")
    find("select#setting_onboarding_state").select(I18n.t("settings.hostings.invite_code_settings.states.invite_only"))
    within("select#setting_onboarding_state") do
      assert_selector "option[selected]", text: I18n.t("settings.hostings.invite_code_settings.states.invite_only")
    end
    click_button I18n.t("settings.hostings.invite_code_settings.generate_tokens")
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

  test "does not show admin settings to non-admin users" do
    VCR.use_cassette("git_repository_provider/fetch_latest_release_notes") do
      # Visit accounts path directly as non-admin user to avoid user menu issues
      visit new_session_path
      within %(form[action='#{sessions_path}']) do
        fill_in "email", with: users(:family_member).email
        fill_in "password", with: user_password_test
        click_on I18n.t("sessions.new.submit")
      end

      # Go directly to accounts (settings) page
      visit accounts_path

      # Assert that admin-only settings are not present in the navigation
      assert_no_selector "li", text: I18n.t("settings.settings_nav.ai_prompts_label")
      assert_no_selector "li", text: I18n.t("settings.settings_nav.api_keys_label")
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
