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
  test "browser notification card is preview gated" do
    get settings_preferences_url
    assert_select "[data-controller='web-push']", count: 0
    user = users(:family_admin)
    user.update!(preferences: user.preferences.merge("preview_features_enabled" => true))
    get settings_preferences_url
    assert_select "[data-controller='web-push']", count: 1
    assert_select "input[name='user[web_push_budget_warnings_enabled]']"
  end

  test "budget warnings default off and are saved only for this user" do
    user = users(:family_admin)
    other = users(:family_member)
    user.update!(preferences: user.preferences.merge("preview_features_enabled" => true))
    assert_not user.web_push_budget_warnings_enabled?
    patch settings_preferences_url, params: { user: { web_push_budget_warnings_enabled: "1" } }
    assert_redirected_to settings_preferences_url
    assert user.reload.web_push_budget_warnings_enabled?
    assert_not other.reload.web_push_budget_warnings_enabled?
    patch settings_preferences_url, params: { user: { web_push_budget_warnings_enabled: "0" } }
    assert_not user.reload.web_push_budget_warnings_enabled?
  end

  test "browser registration inventory contains only current session ids and digests" do
    require Rails.root.join("test/support/web_push_test_helper")
    extend WebPushTestHelper
    user = users(:family_admin)
    user.update!(preferences: user.preferences.merge("preview_features_enabled" => true))
    current_session = Current.session
    device = register_web_push(user: user, session: current_session)
    other = register_web_push(user: user, endpoint: "https://fcm.googleapis.com/other")
    get settings_preferences_url
    inventory = JSON.parse(css_select("[data-web-push-registrations-value]").first["data-web-push-registrations-value"])
    assert_equal({ device.id => device.endpoint_digest }, inventory)
    assert_not_includes inventory.keys, other.id
    assert_not_includes response.body, device.endpoint
    assert_not_includes response.body, device.auth
  end
  test "enabling preview and budget warnings together saves both values" do
    user = users(:family_admin)
    user.update!(preferences: {})
    patch settings_preferences_url, params: { user: { preview_features_enabled: "1", web_push_budget_warnings_enabled: "1" } }
    assert_redirected_to settings_preferences_url
    assert user.reload.preview_features_enabled?
    assert user.web_push_budget_warnings_enabled?
  end

  test "disabling preview in the request prevents enabling budget warnings" do
    user = users(:family_admin)
    user.update!(preferences: { "preview_features_enabled" => true })
    patch settings_preferences_url, params: { user: { preview_features_enabled: "0", web_push_budget_warnings_enabled: "1" } }
    assert_not user.reload.preview_features_enabled?
    assert_not user.web_push_budget_warnings_enabled?
  end
end
