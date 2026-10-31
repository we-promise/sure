require "test_helper"

class Settings::PreferencesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "get" do
    get settings_preferences_url

    assert_response :success
  end

  test "admins see the investing-as-spending toggle" do
    get settings_preferences_url

    assert_response :success
    assert_select "input[name='user[family_attributes][investment_contributions_as_spending]']"
    assert_match I18n.t("settings.preferences.show.investment_contributions_as_spending"), response.body
  end

  test "members do not see the investing-as-spending toggle" do
    sign_in users(:family_member)
    get settings_preferences_url

    assert_response :success
    assert_select "input[name='user[family_attributes][investment_contributions_as_spending]']", count: 0
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

  test "release reminder settings are preview only" do
    get settings_preferences_url
    assert_select "select[name='user[account_release_channel]']", count: 0

    users(:family_admin).update!(preferences: { "preview_features_enabled" => true })
    get settings_preferences_url

    assert_select "select[name='user[account_release_channel]'] option[selected][value='insight']"
    assert_select "input[name='user[account_release_lead_days]'][value='14']"
  end

  test "update stores release reminder channel and lead time" do
    user = users(:family_admin)
    user.update!(preferences: { "preview_features_enabled" => true })

    patch settings_preferences_url, params: { user: { account_release_channel: "both", account_release_lead_days: "30" } }

    assert_redirected_to settings_preferences_url
    user.reload
    assert_equal "both", user.account_release_channel
    assert_equal 30, user.account_release_lead_days
    assert user.preview_features_enabled?
  end

  test "update ignores unknown release reminder values" do
    user = users(:family_admin)
    user.update!(preferences: { "account_release_channel" => "email", "account_release_lead_days" => 7 })

    patch settings_preferences_url, params: { user: { account_release_channel: "sms", account_release_lead_days: "365" } }

    user.reload
    assert_equal "email", user.account_release_channel
    assert_equal 7, user.account_release_lead_days
  end
end
