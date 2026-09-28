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

  test "renders the assistant notes card when AI is enabled" do
    get settings_preferences_url

    assert_response :success
    assert_select "textarea[name='user[assistant_notes]'][maxlength='#{User::ASSISTANT_NOTES_MAX_LENGTH}']"
  end

  test "hides the assistant notes card when AI is disabled" do
    users(:family_admin).update!(ai_enabled: false)

    get settings_preferences_url

    assert_response :success
    assert_select "textarea[name='user[assistant_notes]']", count: 0
  end

  test "hides the assistant notes card when the family uses the external assistant" do
    users(:family_admin).family.update!(assistant_type: "external")

    get settings_preferences_url

    assert_response :success
    assert_select "textarea[name='user[assistant_notes]']", count: 0
  end

  test "shows the assistant notes card when ASSISTANT_TYPE holds an unrecognized value" do
    with_env_overrides("ASSISTANT_TYPE" => "not-a-real-type") do
      get settings_preferences_url
    end

    assert_response :success
    assert_select "textarea[name='user[assistant_notes]']"
  end

  test "update saves assistant notes" do
    patch settings_preferences_url, params: { user: { assistant_notes: "The trust accounts are not mine." } }

    assert_redirected_to settings_preferences_url
    assert_equal I18n.t("settings.preferences.update.assistant_notes_saved"), flash[:notice]
    assert_equal "The trust accounts are not mine.", users(:family_admin).reload.assistant_notes
  end

  test "update with blank assistant notes clears them" do
    user = users(:family_admin)
    user.update!(assistant_notes: "Old note")

    patch settings_preferences_url, params: { user: { assistant_notes: "" } }

    assert_redirected_to settings_preferences_url
    assert_nil user.reload.assistant_notes
  end

  test "update rejects assistant notes over the limit and keeps what was typed" do
    user = users(:family_admin)
    user.update!(assistant_notes: "Old note")
    too_long = "a" * (User::ASSISTANT_NOTES_MAX_LENGTH + 1)

    patch settings_preferences_url, params: { user: { assistant_notes: too_long } }

    assert_response :unprocessable_entity
    assert_select "textarea[name='user[assistant_notes]']"
    assert_includes response.body, too_long
    assert_equal "Old note", user.reload.assistant_notes
  end

  test "saving assistant notes leaves the preview toggle alone" do
    user = users(:family_admin)
    user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))

    patch settings_preferences_url, params: { user: { assistant_notes: "Keep answers short." } }

    user.reload
    assert user.preview_features_enabled?
    assert_equal "Keep answers short.", user.assistant_notes
  end

  test "non-admin members can save their own assistant notes" do
    sign_in users(:family_member)

    patch settings_preferences_url, params: { user: { assistant_notes: "Only mine." } }

    assert_redirected_to settings_preferences_url
    assert_equal "Only mine.", users(:family_member).reload.assistant_notes
    assert_nil users(:family_admin).reload.assistant_notes
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
end
