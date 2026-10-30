require "application_system_test_case"

class SettingsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    # Base settings available to all users
    @settings_links = [
      [ "Accounts", accounts_path ]
    ]

    @settings_links << [ "Bank sync", settings_providers_path ] if @user.admin?

    @settings_links += [
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
      merchants_index = @settings_links.index([ "Merchants", family_merchants_path ])
      @settings_links.insert(merchants_index + 1, [ "Statement Vault", account_statements_path ])
      @settings_links += [
        [ "AI Prompts", settings_ai_prompts_path ],
        [ "API Keys", settings_api_keys_path ]
      ]
    end
  end

  test "Russian settings localize option labels without changing their stored values" do
    @user.update!(locale: "ru")
    @user.family.update!(moniker: "Family")

    [ 1400, 390 ].each do |width|
      page.current_window.resize_to(width, 900)
      visit settings_preferences_path
      assert_selector "html[lang='ru']"
      assert_selector "select#user_locale option[value='ru']", text: "Русский (ru)", visible: :all
      assert_selector "select#user_family_attributes_timezone option[value='Europe/Moscow']", text: "Москва", visible: :all
      assert_selector "select#user_family_attributes_month_start_day option[value='1']", text: "1-е число", visible: :all
      assert_selector "select#user_family_attributes_month_start_day option[value='28']", text: "28-е число", visible: :all
      page.scroll_to(find("#investment_contributions_as_spending_label", visible: :all), align: :center)
      assert_text "Считать переводы в инвестиции расходами"
      assert_text "Доллар США"
      assert page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth"), "preferences must fit the viewport"

      visit settings_profile_path
      assert_field "Название семьи", placeholder: "Введите название семьи"
      assert_text "Сброс и удаление"
      assert_no_text "Домохозяйство"
      assert_no_text "Опасная зона"
      assert page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth"), "settings must fit the viewport"
    end

    visit settings_preferences_path
    page.scroll_to(find("#user_family_attributes_month_start_day", visible: :all), align: :center)
    select "20-е число", from: "user_family_attributes_month_start_day"
    assert_selector "select#user_family_attributes_month_start_day option[value='20'][selected]", visible: :all
    assert_equal 20, @user.family.reload.month_start_day
  end

  test "Russian classifier settings fit desktop and mobile without changing option values" do
    @user.update!(locale: "ru")

    [ 1400, 390 ].each do |width|
      page.current_window.resize_to(width, 900)
      visit settings_classifier_path

      assert_selector "html[lang='ru']"
      assert_selector "h1", text: "Классификатор"
      assert_text "Сопоставитель"
      assert_text "Учитывать заметки"
      assert_selector "input[name='bayes_settings[word_split]'][value='ascii']", visible: :all
      assert_no_selector ".translation_missing"
      assert page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth"), "classifier settings must fit the viewport"
      save_screenshot(Rails.root.join("tmp/screenshots/russian-classifier-#{width}.png"))
    end
  end

  test "can access settings from sidebar" do
    VCR.use_cassette("git_repository_provider/fetch_latest_release_notes") do
      open_settings_from_sidebar
      assert_selector "h1", text: "Accounts"
      assert_current_path accounts_path, ignore_query: true

      @settings_links.each do |name, path|
        click_link name, match: :first
        assert_selector "h1", text: name
        assert_current_path path
      end
    end
  end

  test "can update self hosting settings" do
    sign_in users(:sure_support_staff)
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    Provider::Registry.stubs(:get_provider).with(:openai).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:anthropic).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:twelve_data).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:yahoo_finance).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:rentcast).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:realie).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:chimnie).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:github).returns(stub(fetch_latest_release_notes: nil, fetch_release_notes: nil))
    open_settings_from_sidebar
    assert_selector "li", text: "Self-Hosting"
    click_link "Self-Hosting", match: :first
    assert_current_path settings_hosting_path
    assert_selector "h1", text: "Self-Hosting"
    find("select#setting_onboarding_state").select("Invite-only")
    within("select#setting_onboarding_state") do
      assert_selector "option[selected]", text: "Invite-only"
    end
    click_button "Generate new code"
    assert_selector 'span[data-clipboard-target="source"]', visible: true, count: 1 # invite code copy widget
    copy_button = find('button[data-action="clipboard#copy"]', match: :first) # Find the first copy button (adjust if needed)
    page.execute_script("Object.defineProperty(navigator, 'clipboard', { value: { writeText: () => Promise.resolve() }, writable: true, configurable: true })") # Mock clipboard API due to browser security restrictions in tests
    copy_button.click
    assert_selector 'span[data-clipboard-target="iconSuccess"]', visible: true, count: 1 # text copied and icon changed to checkmark
  end

  test "does not show payment link if self hosting" do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    open_settings_from_sidebar
    assert_no_selector "li", text: I18n.t("settings.settings_nav.payment_label")
  end

  # Escape is also the settings nav's hotkey back to the page before settings.
  test "Escape closes an open dialog instead of leaving settings" do
    visit settings_api_keys_path
    click_on I18n.t("settings.api_keys.index.revoke_key"), match: :first
    assert_selector "dialog#confirm-dialog[open]"

    page.send_keys(:escape)

    assert_no_selector "dialog#confirm-dialog[open]"
    assert_current_path settings_api_keys_path
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
      assert_no_selector "li", text: "API Keys"
      assert_no_selector "li", text: "Bank sync"
      assert_no_selector "li", text: "Statement Vault"
    end
  end

  private

    def open_settings_from_sidebar
      user_menu = find("div[data-testid=user-menu]", match: :first, visible: :visible)
      within user_menu do
        find("[data-DS--popover-target='button']", match: :first).click
        click_link "Settings", match: :first
      end
    end
end
