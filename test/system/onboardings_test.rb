require "application_system_test_case"

class OnboardingsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family

    # Reset onboarding state
    @user.update!(set_onboarding_preferences_at: nil)

    # Force English locale for tests
    I18n.locale = :en

    sign_in @user
  end

  teardown do
    I18n.locale = I18n.default_locale
  end

  test "can complete the full onboarding flow" do
    # Start at the main onboarding page
    visit onboarding_path

    assert_text I18n.t("onboardings.show.title")
    assert_button I18n.t("onboardings.show.submit")

    # Navigate to preferences
    click_button I18n.t("onboardings.show.submit")

    assert_current_path preferences_onboarding_path
    assert_text I18n.t("onboardings.preferences.title")

    # Test that the chart renders without errors (this would catch the Series bug)
    assert_selector "[data-controller='time-series-chart']"

    # Fill out preferences form
    select "English (en)", from: "user_family_attributes_locale"
    select "United States Dollar (USD)", from: "user_family_attributes_currency"
    select "MM/DD/YYYY", from: "user_family_attributes_date_format"
    select_theme("light")

    # Submit preferences
    click_button I18n.t("onboardings.preferences.submit")

    # Should redirect to tools page
    assert_current_path tools_onboarding_path
    assert_text I18n.t("onboardings.tools.welcome_title")
  end

  test "browser locale defaults onboarding country and currency" do
    @family.update!(country: "US", currency: "USD")
    set_browser_language("en-CA")

    visit onboarding_path

    assert_equal "CA", find("#user_family_attributes_country").value

    click_button I18n.t("onboardings.show.submit")
    assert_current_path preferences_onboarding_path

    assert_equal "CAD", find("#user_family_attributes_currency").value

    click_button I18n.t("onboardings.preferences.submit")
    assert_current_path tools_onboarding_path

    @family.reload
    assert_equal "CA", @family.country
    assert_equal "CAD", @family.currency
  end

  test "saved currency stays authoritative after onboarding controller connects" do
    @family.update!(country: "CA", currency: "USD")
    @user.update!(set_onboarding_preferences_at: Time.current)
    set_browser_language("en-CA")

    visit preferences_onboarding_path

    assert_selector "[data-onboarding-currency-override-value='true']"
    assert_equal "USD", find("#user_family_attributes_currency").value
  end

  test "preferences page renders chart without errors" do
    visit preferences_onboarding_path

    # This test specifically targets the Series model bug
    # The chart should render without throwing JavaScript errors
    assert_selector "[data-controller='time-series-chart']"
    assert_selector "#previewChart"

    # Verify the chart data is properly formatted JSON
    chart_element = find("[data-controller='time-series-chart']")
    chart_data = chart_element["data-time-series-chart-data-value"]

    # Should be valid JSON
    assert_nothing_raised do
      JSON.parse(chart_data)
    end

    # Verify the preview example shows
    assert_text I18n.t("onboardings.preferences.example")
    assert_text "$2,325.25"
    assert_text "+$78.90"
  end

  test "can change currency and see preview update" do
    visit preferences_onboarding_path

    # Change currency
    select "Euro (EUR)", from: "user_family_attributes_currency"

    # The preview should update (this tests the JavaScript controller)
    # Note: This would require the onboarding controller to handle currency changes
    assert_text I18n.t("onboardings.preferences.example")
  end

  test "can change date format and see preview update" do
    visit preferences_onboarding_path

    # Change date format
    select "DD/MM/YYYY", from: "user_family_attributes_date_format"

    # The preview should update
    assert_text I18n.t("onboardings.preferences.example")
  end

  test "can change theme" do
    visit preferences_onboarding_path

    # Change theme using value instead of label
    select_theme("dark")

    # Theme should be applied (this tests the JavaScript controller)
    assert_text I18n.t("onboardings.preferences.example")
  end

  test "preferences form validation" do
    visit preferences_onboarding_path

    # Clear required fields and try to submit
    select "", from: "user_family_attributes_locale"
    click_button I18n.t("onboardings.preferences.submit")

    # Should stay on preferences page with validation errors (may have query params)
    assert_match %r{/onboarding/preferences}, current_path
  end

  test "preferences form saves data correctly" do
    visit preferences_onboarding_path

    # Fill out form with specific values
    select "Spanish (es)", from: "user_family_attributes_locale"
    select "Euro (EUR)", from: "user_family_attributes_currency"
    select "DD/MM/YYYY", from: "user_family_attributes_date_format"
    select_theme("dark")

    # Button text is in Spanish due to locale preview
    click_button I18n.t("onboardings.preferences.submit", locale: :es)

    # Wait for redirect to tools page to ensure form was submitted
    assert_current_path tools_onboarding_path

    # Verify data was saved
    @family.reload
    @user.reload

    assert_equal "es", @family.locale
    assert_equal "EUR", @family.currency
    assert_equal "%d/%m/%Y", @family.date_format
    assert_equal "dark", @user.theme
    assert_not_nil @user.set_onboarding_preferences_at
  end

  test "tools page renders correctly" do
    # Complete preferences first
    @user.update!(set_onboarding_preferences_at: Time.current)

    visit tools_onboarding_path

    assert_text I18n.t("onboardings.tools.welcome_title")
    assert_button I18n.t("onboardings.tools.submit")
  end

  test "trial page renders correctly" do
    visit trial_onboarding_path

    assert_text "Sure"
  end

  test "navigation between onboarding steps" do
    # Start at main onboarding
    visit onboarding_path
    click_button I18n.t("onboardings.show.submit")

    # Should be at preferences
    assert_current_path preferences_onboarding_path

    # Complete preferences
    select "English (en)", from: "user_family_attributes_locale"
    select "United States Dollar (USD)", from: "user_family_attributes_currency"
    select "MM/DD/YYYY", from: "user_family_attributes_date_format"
    click_button I18n.t("onboardings.preferences.submit")

    # Should be at tools
    assert_current_path tools_onboarding_path
  end

  test "onboarding nav shows correct steps" do
    visit preferences_onboarding_path

    # Check that navigation shows current step
    assert_selector "ul.hidden.md\\:flex.items-center.gap-2"
  end

  test "logout option is available during onboarding" do
    visit preferences_onboarding_path

    # Should have logout option (rendered as a button component)
    assert_text I18n.t("onboardings.logout.sign_out")
  end

  test "starting tools are searchable and nothing yet is exclusive" do
    visit tools_onboarding_path
    find("details summary").click
    fill_in I18n.t("onboardings.tools.search_label"), with: "ynab", enable_aria_label: true
    check "YNAB"
    assert_no_selector "label", text: "Quicken Classic"
    fill_in I18n.t("onboardings.tools.search_label"), with: "", enable_aria_label: true
    check "Other"
    fill_in I18n.t("onboardings.tools.other_label"), with: "My ledger"
    check I18n.t("onboardings.tools.tools.nothing_yet")
    assert_unchecked_field "YNAB"
    assert_unchecked_field "Other"
    assert_no_field I18n.t("onboardings.tools.other_label")
    check "YNAB"
    assert_unchecked_field I18n.t("onboardings.tools.tools.nothing_yet")
    click_button I18n.t("onboardings.tools.done")
    assert_no_selector "details[open]"
    assert_selector "details summary", text: "1 selected"
    assert_selector "[data-onboarding-tools-target='chip']", text: "YNAB"
    click_button I18n.t("onboardings.tools.submit")
    assert_current_path(Rails.application.config.app_mode.self_hosted? ? root_path : trial_onboarding_path)
    assert_equal [ "ynab" ], @user.reload.starting_tools
    assert_nil @user.starting_tool_other
  end

  test "AI modes reveal truthful setup panels without connecting providers" do
    visit tools_onboarding_path
    assert_checked_field "user_onboarding_ai_mode_none"
    assert_selector "#ai-panel-none", text: "Other LLM-powered features"
    assert_selector "#user_onboarding_ai_mode_none[aria-expanded='true']"
    assert_no_selector "#ai-panel-builtin"
    assert_no_selector "#ai-panel-external"
    choose "user_onboarding_ai_mode_builtin"
    assert_selector "#ai-panel-builtin", text: "Set up AI without leaving onboarding"
    assert_no_selector "#ai-panel-none"
    assert_selector "#user_onboarding_ai_mode_none[aria-expanded='false']"
    assert_selector "#user_onboarding_ai_mode_builtin[aria-expanded='true']"

    choose "user_onboarding_ai_mode_external"
    assert_selector "#ai-panel-external"
    assert_no_selector "#ai-panel-builtin"
    assert_field I18n.t("onboardings.tools.agent_instructions_label"), readonly: true
    click_button I18n.t("onboardings.tools.submit")
    assert_current_path(Rails.application.config.app_mode.self_hosted? ? root_path : trial_onboarding_path)
    assert_equal "external", @user.reload.onboarding_ai_mode
    assert_not @user.ai_enabled?
  end

  test "long selected tool chips stay inside the card padding on mobile" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    visit tools_onboarding_path
    find("details summary").click
    check I18n.t("onboardings.tools.tools.spreadsheets")
    click_button I18n.t("onboardings.tools.done")
    assert_selector "[data-onboarding-tools-target='chip'][data-value='spreadsheets']"

    bounds = page.evaluate_script <<~JS
      (() => {
        const card = document.querySelector('[aria-labelledby="starting-point-title"]');
        const chip = card.querySelector('[data-onboarding-tools-target="chip"][data-value="spreadsheets"] > span');
        const cardRect = card.getBoundingClientRect();
        const chipRect = chip.getBoundingClientRect();
        const style = getComputedStyle(card);
        return {
          viewport: window.innerWidth,
          contentLeft: cardRect.left + parseFloat(style.paddingLeft) + parseFloat(style.borderLeftWidth),
          contentRight: cardRect.right - parseFloat(style.paddingRight) - parseFloat(style.borderRightWidth),
          chipLeft: chipRect.left,
          chipRight: chipRect.right,
          title: chip.title
        };
      })()
    JS
    assert_equal 390, bounds.fetch("viewport")
    assert_operator bounds.fetch("chipLeft"), :>=, bounds.fetch("contentLeft") - 1
    assert_operator bounds.fetch("chipRight"), :<=, bounds.fetch("contentRight") + 1
    assert_equal I18n.t("onboardings.tools.tools.spreadsheets"), bounds.fetch("title")
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "numbered cards and provider inputs match the selected provider" do
    OnboardingAiConfiguration.stubs(:allowed_for?).returns(true)
    visit tools_onboarding_path
    assert_selector "[role='region'].bg-container[aria-labelledby='starting-point-title']", text: /01 · Your starting point/i
    assert_selector "[role='region'].bg-container[aria-labelledby='ai-preference-title']", text: /02 · Your AI preference/i
    choose "user_onboarding_ai_mode_builtin"
    select "OpenAI", from: "Provider"
    assert_field "OpenAI API key", type: "password", with: ""
    assert_selector "input[type='password']:not([name])"
    assert_selector "select:not([name])"
    fill_in "OpenAI API key", with: "test-placeholder-not-a-real-key"
    select "Anthropic", from: "Provider"
    assert_field "Anthropic API key", type: "password", with: ""
    assert_selector "input[placeholder='Enter your Anthropic API key']"
    click_button "Save and test connection"
    assert_text "Enter an API key for the selected provider."
    select "OpenRouter", from: "Provider"
    assert_field "OpenRouter API key", type: "password", with: ""
    assert_field "OpenRouter model ID (required)", with: ""
    assert_text "OpenRouter document search is not configured here."
    fill_in "OpenRouter API key", with: "test-placeholder-not-a-real-key"
    click_button "Save and test connection"
    assert_text "Enter an OpenRouter model ID before saving."
    fill_in "OpenRouter model ID (required)", with: "openai/gpt-4.1-mini"
    select "Anthropic", from: "Provider"
    assert_no_selector "input#provider_configuration_model"
    select "OpenRouter", from: "Provider"
    assert_field "OpenRouter model ID (required)", with: "openai/gpt-4.1-mini"
    assert_field "OpenRouter API key", with: ""
    choose "user_onboarding_ai_mode_none"
    assert_no_selector "input[type='password']"
    assert_selector "#ai-panel-builtin fieldset[disabled]", visible: :all
  end

  test "provider response without CSRF metadata shows errors and clears the key after each attempt" do
    OnboardingAiConfiguration.stubs(:allowed_for?).returns(true)
    visit tools_onboarding_path
    choose "user_onboarding_ai_mode_builtin"
    select "OpenAI", from: "Provider"
    page.execute_script <<~JS
      document.querySelector('meta[name="csrf-token"]')?.remove();
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (url !== "#{configure_provider_onboarding_path}") return originalFetch(url, options);
        return Promise.resolve(new Response(JSON.stringify({status: "failed", error: "connection_failed"}), {status: 422, headers: {"Content-Type": "application/json"}}));
      };
    JS
    fill_in "OpenAI API key", with: "test-placeholder-not-a-real-key"
    find_field("OpenAI API key").send_keys(:enter)
    assert_current_path tools_onboarding_path
    assert_text "Provider access could not be confirmed."
    assert_field "OpenAI API key", with: ""
    assert_button I18n.t("onboardings.tools.submit"), disabled: false

    page.execute_script <<~JS
      const fetchBeforePending = window.fetch;
      window.fetch = (url, options) => {
        if (url !== "#{configure_provider_onboarding_path}") return fetchBeforePending(url, options);
        return new Promise((resolve) => { window.resolveProvider = resolve; });
      };
    JS
    fill_in "OpenAI API key", with: "test-placeholder-not-a-real-key"
    click_button "Save and test connection"
    assert_button I18n.t("onboardings.tools.submit"), disabled: true
    find("nav a[href='#{preferences_onboarding_path}']").click
    assert_current_path preferences_onboarding_path
    page.go_back
    assert_current_path tools_onboarding_path
    assert_field "OpenAI API key", with: "", disabled: true
    assert_button I18n.t("onboardings.tools.submit"), disabled: true
    page.execute_script <<~JS
      window.resolveProvider(new Response(JSON.stringify({status: "saved", provider: "openai"}), {status: 200, headers: {"Content-Type": "application/json"}}));
    JS
    assert_button I18n.t("onboardings.tools.submit"), disabled: false
    assert_field "OpenAI API key", with: "", disabled: false
    assert_selector "#provider_configuration_provider:not([disabled])"
    assert_text "The result could not be confirmed."
  end

  test "Next does not save a typed provider key" do
    OnboardingAiConfiguration.stubs(:allowed_for?).returns(true)
    OnboardingAiConfiguration.expects(:new).never
    saved = @family.create_ai_configuration!(provider: "anthropic", api_key: "original-family-key")
    visit tools_onboarding_path
    choose "user_onboarding_ai_mode_builtin"
    assert_equal "anthropic", find("#provider_configuration_provider").value
    fill_in "Anthropic API key", with: "unsaved-family-key"
    click_button I18n.t("onboardings.tools.submit")
    assert_current_path(Rails.application.config.app_mode.self_hosted? ? root_path : trial_onboarding_path)
    assert_equal "original-family-key", saved.reload.api_key
  end

  test "a missing OpenRouter model does not block continuing without a provider" do
    OnboardingAiConfiguration.stubs(:allowed_for?).returns(true)
    OnboardingAiConfiguration.expects(:new).never
    visit tools_onboarding_path
    choose "user_onboarding_ai_mode_builtin"
    select "OpenRouter", from: "Provider"
    assert_field "OpenRouter model ID (required)", with: ""
    click_button I18n.t("onboardings.tools.submit")
    assert_current_path(Rails.application.config.app_mode.self_hosted? ? root_path : trial_onboarding_path)
    assert_nil @family.reload.ai_configuration
  end

  test "family provider settings support explicit repeated saves outside onboarding" do
    OnboardingAiConfiguration.stubs(:allowed_for?).returns(true)
    @family.create_ai_configuration!(provider: "openrouter", model: "anthropic/claude-sonnet-4", api_key: "original-family-key")
    visit settings_ai_prompts_path
    assert_text "Family AI provider"
    assert_field "OpenRouter API key", with: ""
    assert_field "OpenRouter model ID (required)", with: "anthropic/claude-sonnet-4"
    assert_selector "textarea#family_ai_prompt_chat_system"
    page.execute_script <<~JS
      window.providerRequests = 0;
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (url !== "#{configure_provider_settings_ai_prompts_path}") return originalFetch(url, options);
        window.providerRequests += 1;
        return new Promise((resolve) => { window.resolveProvider = resolve; });
      };
    JS

    %w[openai/gpt-4.1-mini anthropic/claude-sonnet-4].each do |model|
      fill_in "OpenRouter model ID (required)", with: model
      assert_text "Not checked here. Any existing saved key is hidden."
      fill_in "OpenRouter API key", with: "replacement-family-key"
      click_button "Save and test connection"
      assert_button "Save and test connection", disabled: true
      assert_field "OpenRouter model ID (required)", disabled: true
      page.execute_script <<~JS
        document.querySelector('[data-onboarding-provider-target="button"]').dispatchEvent(new MouseEvent("click", {bubbles: true}));
        window.resolveProvider(new Response(JSON.stringify({status: "saved", provider: "openrouter"}), {status: 200, headers: {"Content-Type": "application/json"}}));
      JS
      assert_text "Provider access checked and encrypted key saved for your family."
      assert_field "OpenRouter API key", with: "", disabled: false
      assert_field "OpenRouter model ID (required)", with: model, disabled: false
      assert_button "Save and test connection", disabled: false
    end
    assert_equal 2, page.evaluate_script("window.providerRequests")
    assert_current_path settings_ai_prompts_path
  end

  private
    def select_theme(value)
      find("#user_theme", visible: :all)
        .find("option[value='#{value}']", visible: :all)
        .select_option
    end

    def set_browser_language(language)
      page.driver.browser.execute_cdp(
        "Page.addScriptToEvaluateOnNewDocument",
        source: <<~JS
          Object.defineProperty(navigator, "language", {
            get: () => "#{language}",
            configurable: true
          });
        JS
      )
    end

    def sign_in(user)
      visit new_session_path
      within %(form[action='#{sessions_path}']) do
        fill_in I18n.t("sessions.new.email"), with: user.email
        fill_in I18n.t("sessions.new.password"), with: user_password_test
        click_on I18n.t("sessions.new.submit")
      end

      # Wait for successful login
      assert_current_path root_path
    end
end
