require "test_helper"

class Settings::PreferencesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "get" do
    get settings_preferences_url

    assert_response :success
  end

  test "group moniker uses group currencies copy and hides legacy currency field" do
    users(:family_admin).family.update!(moniker: "Group")

    get settings_preferences_url

    assert_response :success
    assert_includes response.body, "Group Currencies"
    assert_includes response.body, "your group"
    assert_select "select[name='user[family_attributes][currency]']", count: 0
  end

  test "renders preview features toggle for non-admin users too" do
    sign_in users(:family_member)
    get settings_preferences_url

    assert_response :success
    assert_includes response.body, "Enable preview features"
  end

  test "update toggles preview_features_enabled on" do
    user = users(:family_admin)
    assert_not user.preview_features_enabled?

    patch settings_preferences_url, params: { user: { preview_features_enabled: "1" } }

    assert_redirected_to settings_preferences_url
    assert user.reload.preview_features_enabled?
  end

  test "update toggles preview_features_enabled off" do
    user = users(:family_admin)
    user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    assert user.preview_features_enabled?

    patch settings_preferences_url, params: { user: { preview_features_enabled: "0" } }

    assert_redirected_to settings_preferences_url
    assert_not user.reload.preview_features_enabled?
  end

  test "household budget toggle and sharing card only render once personal_budgets is on" do
    user = users(:family_admin)
    user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))

    get settings_preferences_url
    assert_response :success
    assert_not_includes response.body, I18n.t("settings.preferences.show.household_budget_enabled")
    assert_not_includes response.body, I18n.t("settings.preferences.show.budget_sharing_title")

    user.family.update!(personal_budgets: true)

    get settings_preferences_url
    assert_response :success
    assert_includes response.body, I18n.t("settings.preferences.show.household_budget_enabled")
    assert_includes response.body, I18n.t("settings.preferences.show.budget_sharing_title")
  end

  test "hides the sharing card when personal_budgets is on but preview features are off" do
    user = users(:family_admin)
    user.family.update!(personal_budgets: true)
    assert_not user.preview_features_enabled?

    get settings_preferences_url

    assert_response :success
    assert_not_includes response.body, I18n.t("settings.preferences.show.household_budget_enabled")
    assert_not_includes response.body, I18n.t("settings.preferences.show.budget_sharing_title")
  end

  test "monthly visibility shares Home settings and preserves other preferences" do
    user = users(:family_admin)
    user.update!(preferences: { "preview_features_enabled" => true, "hidden_sections" => [ "money_flow" ], "monthly_spending_filters" => { "period" => "this_year" } })
    get settings_preferences_url
    assert_select "input[name='user[monthly_spending_visible]'][checked]", count: 1
    patch settings_preferences_url, params: { user: { monthly_spending_visible: "0" } }
    assert_includes user.reload.dashboard_hidden_sections, "monthly_spending"
    assert_includes user.dashboard_hidden_sections, "money_flow"
    assert_equal "this_year", user.preferences.dig("monthly_spending_filters", "period")
    get root_url
    assert_select "turbo-frame#monthly_spending_chart", count: 0
    patch settings_preferences_url, params: { user: { monthly_spending_visible: "1" } }
    assert_not_includes user.reload.dashboard_hidden_sections, "monthly_spending"
    assert_includes user.dashboard_hidden_sections, "money_flow"
  end

  test "monthly visibility setting is unavailable without preview access" do
    get settings_preferences_url
    assert_select "input[name='user[monthly_spending_visible]']", count: 0
    patch settings_preferences_url, params: { user: { monthly_spending_visible: "0" } }
    assert_not_includes users(:family_admin).reload.dashboard_hidden_sections, "monthly_spending"
  end
end
