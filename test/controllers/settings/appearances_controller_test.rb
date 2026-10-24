require "test_helper"

class Settings::AppearancesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "group by date toggle is hidden when compact table is disabled" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true, "transactions_compact" => false))

    get settings_appearance_url

    assert_response :success
    assert_no_selector_for_group_by_date
  end

  test "group by date toggle is shown when compact table is enabled" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true, "transactions_compact" => true))

    get settings_appearance_url

    assert_response :success
    assert_select "input#user_transactions_group_by_date"
  end

  test "group by date toggle is hidden when preview features are disabled entirely" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false, "transactions_compact" => true))

    get settings_appearance_url

    assert_response :success
    assert_no_selector_for_group_by_date
  end

  test "show notes toggle is shown when compact table is enabled" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true, "transactions_compact" => true))

    get settings_appearance_url

    assert_response :success
    assert_select "input#user_transactions_show_notes"
  end

  test "show notes toggle is hidden when compact table is disabled" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true, "transactions_compact" => false))

    get settings_appearance_url

    assert_response :success
    assert_select "input#user_transactions_show_notes", count: 0
  end

  test "show notes toggle is off by default" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true, "transactions_compact" => true))

    get settings_appearance_url

    assert_response :success
    assert_select "input#user_transactions_show_notes:not([checked])"
  end

  test "updating show notes persists the preference" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true, "transactions_compact" => true))

    patch settings_appearance_url, params: { user: { transactions_show_notes: "1" } }

    assert_redirected_to settings_appearance_url
    assert @user.reload.transactions_show_notes?
  end

  private
    def assert_no_selector_for_group_by_date
      assert_select "input#user_transactions_group_by_date", count: 0
    end
end
