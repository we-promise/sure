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

  private
    def assert_no_selector_for_group_by_date
      assert_select "input#user_transactions_group_by_date", count: 0
    end
end
