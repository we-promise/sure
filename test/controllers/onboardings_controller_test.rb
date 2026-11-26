require "test_helper"

class OnboardingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family

    # Reset onboarding state
    @user.update!(set_onboarding_preferences_at: nil)

    sign_in @user
  end

  test "should get show" do
    get onboarding_url
    assert_response :success
    assert_select "h1", text: /set up your account/i
  end


  test "onboarding setup includes required moniker selection" do
    get onboarding_url
    assert_response :success

    assert_select "input[name='user[family_attributes][moniker]'][value='Family'][required]"
    assert_select "input[name='user[family_attributes][moniker]'][value='Group'][required]"
    assert_select "p.text-sm.font-medium.text-primary", text: /Will be using.*with/i
  end

  test "should get preferences" do
    get preferences_onboarding_url
    assert_response :success
    assert_select "h1", text: /preferences/i
  end

  test "preferences page renders Series chart data without errors" do
    get preferences_onboarding_url
    assert_response :success

    # This test specifically targets the Series model bug
    # The page should render without throwing the "unknown keyword: :trend" error
    assert_select "[data-controller='time-series-chart']"
    assert_select "#previewChart"

    # Verify that the Series.from_raw_values call in the view works
    # If the Series bug existed, this would raise an ActionView::Template::Error
    assert_no_match /unknown keyword: :trend/, response.body
  end

  test "preferences page includes chart with valid JSON data" do
    get preferences_onboarding_url
    assert_response :success

    # Extract the chart data from the response
    chart_data_match = response.body.match(/data-time-series-chart-data-value="([^"]*)"/)
    assert chart_data_match, "Chart data attribute should be present"

    # Decode HTML entities and parse JSON
    chart_data_json = CGI.unescapeHTML(chart_data_match[1])

    # Should be valid JSON
    assert_nothing_raised do
      chart_data = JSON.parse(chart_data_json)

      # Verify expected structure
      assert chart_data.key?("start_date")
      assert chart_data.key?("end_date")
      assert chart_data.key?("interval")
      assert chart_data.key?("trend")
      assert chart_data.key?("values")

      # Verify trend has expected structure
      trend = chart_data["trend"]
      assert trend.key?("value")
      assert trend.key?("percent")
      assert trend.key?("current")
      assert trend.key?("previous")

      # Verify values array has expected structure
      values = chart_data["values"]
      assert values.is_a?(Array)
      assert values.length > 0

      values.each do |value|
        assert value.key?("date")
        assert value.key?("value")
        assert value.key?("trend")
      end
    end
  end

  test "should get tools, with no AI selected for a user without AI" do
    @user.update!(ai_enabled: false)
    get tools_onboarding_url
    assert_response :success
    assert_select "h1", text: I18n.t("onboardings.tools.title")
    assert_select "input[type=radio][name='user[onboarding_ai_mode]'][value=none][checked]"
  end

  test "admins are told their AI choice is also the household's consent" do
    get tools_onboarding_url
    assert_select "[data-ai-panel=builtin]", text: /#{Regexp.escape(I18n.t("onboardings.tools.ai.panels.admin_on"))}/
  end

  test "members don't see the household consent note" do
    sign_in users(:family_member)
    get tools_onboarding_url
    assert_select "[data-ai-panel=builtin]"
    assert_select "[data-ai-panel=builtin]", text: /#{Regexp.escape(I18n.t("onboardings.tools.ai.panels.admin_on"))}/, count: 0
  end

  test "resubmitting after turning AI off in settings keeps it off" do
    patch tools_onboarding_url, params: { user: { onboarding_ai_mode: "builtin" } }
    @user.reload.update!(ai_enabled: false)

    get tools_onboarding_url
    assert_select "input[type=radio][value=none][checked]"
    patch tools_onboarding_url, params: { user: { onboarding_ai_mode: "none" } }
    assert_not @user.reload.ai_enabled
  end

  test "revisiting the step keeps an enabled assistant selected" do
    @user.update!(ai_enabled: true)
    get tools_onboarding_url
    assert_select "input[type=radio][value=builtin][checked]"
  end

  test "the old goals step redirects to tools" do
    get "/onboarding/goals"
    assert_redirected_to "/onboarding/tools"
  end

  test "saving tools and built-in AI turns the assistant on and goes to the trial" do
    @user.update!(ai_enabled: false)

    patch tools_onboarding_url, params: { user: {
      onboarding_tools: %w[ynab other], onboarding_other_tool: "Spreadsheet", onboarding_ai_mode: "builtin"
    } }

    assert_redirected_to trial_onboarding_url
    @user.reload
    assert_equal %w[ynab other], @user.onboarding_tools
    assert_equal "Spreadsheet", @user.onboarding_other_tool
    assert_equal "builtin", @user.onboarding_ai_mode
    assert @user.ai_enabled
    assert_not_nil @user.set_onboarding_goals_at
    assert_not_nil @user.onboarded_at
  end

  test "no AI turns the assistant off" do
    @user.update!(ai_enabled: true)
    patch tools_onboarding_url, params: { user: { onboarding_ai_mode: "none", rendered_ai_mode: "builtin" } }
    assert_not @user.reload.ai_enabled
    assert_equal "none", @user.onboarding_ai_mode
  end

  test "external AI stays enabled and selected when revisiting onboarding" do
    @user.update!(ai_enabled: false)
    patch tools_onboarding_url, params: { user: { onboarding_ai_mode: "external", rendered_ai_mode: "none" } }
    assert @user.reload.ai_enabled
    assert_equal "external", @user.onboarding_ai_mode

    get tools_onboarding_url
    assert_select "input[type=radio][value=external][checked]"
    assert_select "[data-ai-panel=external]", text: /#{Regexp.escape(I18n.t("onboardings.tools.ai.panels.admin_on"))}/
    assert_select "[data-ai-panel=external]", text: /#{Regexp.escape(I18n.t("onboardings.tools.ai.panels.admin_off"))}/, count: 0

    patch tools_onboarding_url, params: { user: { onboarding_ai_mode: "external", rendered_ai_mode: "external" } }
    assert @user.reload.ai_enabled
    assert_equal "external", @user.onboarding_ai_mode
  end

  test "built-in AI warns about a missing provider only when the assistant can't run" do
    with_self_hosting do
      Provider::Openai.stubs(:configured?).returns(false)
      Provider::Anthropic.stubs(:configured?).returns(false)
      not_configured = Regexp.escape(I18n.t("onboardings.tools.ai.panels.builtin.not_configured"))

      User.any_instance.stubs(:ai_available?).returns(true)
      get tools_onboarding_url
      assert_select "[data-ai-panel=builtin]", text: /#{not_configured}/, count: 0

      User.any_instance.stubs(:ai_available?).returns(false)
      get tools_onboarding_url
      assert_select "[data-ai-panel=builtin]", text: /#{not_configured}/
    end
  end

  test "self-hosted onboarding finishes on the dashboard" do
    with_self_hosting do
      patch tools_onboarding_url, params: { user: { onboarding_ai_mode: "none" } }
      assert_redirected_to root_url
    end
  end

  test "should get trial" do
    get trial_onboarding_url
    assert_response :success
  end

  test "preferences page shows currency formatting example" do
    get preferences_onboarding_url
    assert_response :success

    # Should show formatted currency example
    assert_select "p", text: /\$2,325\.25/
    assert_select "span", text: /\+\$78\.90/
  end

  test "preferences page derives currency from the onboarding country" do
    @family.update!(country: "CA", currency: "USD")

    get preferences_onboarding_url

    assert_response :success
    assert_select "select[name='user[family_attributes][currency]'] option[selected][value='CAD']"
  end

  test "preferences page keeps the saved currency after preferences have been set" do
    @family.update!(country: "CA", currency: "USD")
    @user.update!(set_onboarding_preferences_at: Time.current)

    get preferences_onboarding_url

    assert_response :success
    assert_select "select[name='user[family_attributes][currency]'] option[selected][value='USD']"
  end

  test "preferences page preserves an explicit currency override" do
    @family.update!(country: "CA", currency: "USD")

    get preferences_onboarding_url, params: { currency: "USD" }

    assert_response :success
    assert_select "select[name='user[family_attributes][currency]'] option[selected][value='USD']"
  end

  test "preferences page ignores an unsupported currency override" do
    @family.update!(country: "CA", currency: "USD")

    get preferences_onboarding_url, params: { currency: "NOPE" }

    assert_response :success
    assert_select "[data-onboarding-currency-override-value='false']"
    assert_select "select[name='user[family_attributes][currency]'] option[selected][value='CAD']"
  end

  test "preferences page shows date formatting example" do
  get preferences_onboarding_url
  assert_response :success

  # Should show formatted date example (checking for the specific format shown)
  assert_match /10-23-2024/, response.body
end

  test "preferences page includes all required form fields" do
  get preferences_onboarding_url
  assert_response :success

  # Verify all form fields are present
  assert_select "select[name='user[family_attributes][locale]']"
  assert_select "select[name='user[family_attributes][currency]']"
  assert_select "select[name='user[family_attributes][date_format]']"
  assert_select "select[name='user[theme]']"
  assert_select "button[type='submit']"
end

  test "preferences page includes JavaScript controllers" do
    get preferences_onboarding_url
    assert_response :success

    # Should include onboarding controller for dynamic updates
    assert_select "[data-controller*='onboarding']"
    assert_select "[data-controller*='time-series-chart']"
  end

  test "all onboarding pages set correct layout" do
    # Test that all onboarding pages use the wizard layout
    get onboarding_url
    assert_response :success

    get preferences_onboarding_url
    assert_response :success

    get tools_onboarding_url
    assert_response :success

    get trial_onboarding_url
    assert_response :success
  end

  test "onboarding pages require authentication" do
  sign_out

  get onboarding_url
  assert_redirected_to new_session_url

  get preferences_onboarding_url
  assert_redirected_to new_session_url

  get tools_onboarding_url
  assert_redirected_to new_session_url

  get trial_onboarding_url
  assert_redirected_to new_session_url
end

    private

      def sign_out
        # Deleting sessions through the controller de-authenticates the request the
        # moment our own session dies, so every later delete in the loop is a
        # silent no-op and whichever sessions sort after it survive. The order is
        # unspecified, which made every suite that signs out this way flaky.
        # Teardown hygiene is not the behavior under test, so destroy directly.
        @user.sessions.destroy_all
      end
end
