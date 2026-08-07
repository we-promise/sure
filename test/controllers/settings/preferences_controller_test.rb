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
    assert_not_includes response.body, "treat_investment_contributions_as_transfers"
  end

  test "non-admin users cannot change family reporting preferences" do
    sign_in users(:family_member)
    family = users(:family_member).family

    patch settings_preferences_url, params: { family: { treat_investment_contributions_as_transfers: "1" } }

    assert_response :not_found
    assert_not family.reload.treat_investment_contributions_as_transfers?
  end

  test "renders family reporting preference with title and subtitle for admins" do
    get settings_preferences_url

    assert_select "h2", text: "Family Reporting"
    assert_includes response.body, "Control how investment contributions appear in your family reports and budgets"
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

  test "update toggles investment contributions as transfers" do
    user = users(:family_admin)
    assert_not user.family.treat_investment_contributions_as_transfers?

    patch settings_preferences_url, params: { family: { treat_investment_contributions_as_transfers: "1" } }

    assert_redirected_to settings_preferences_url
    assert user.family.reload.treat_investment_contributions_as_transfers?
    assert users(:family_member).family.reload.treat_investment_contributions_as_transfers?
  end
end
