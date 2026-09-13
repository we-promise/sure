require "test_helper"

class Settings::AppearancesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "show renders successfully" do
    get settings_appearance_path
    assert_response :success
  end

  test "update persists show_counterparty_account preference" do
    patch settings_appearance_path, params: { user: { show_counterparty_account: "0" } }
    assert_redirected_to settings_appearance_path
    assert_equal false, @user.reload.show_counterparty_account?

    patch settings_appearance_path, params: { user: { show_counterparty_account: "1" } }
    assert @user.reload.show_counterparty_account?
  end

  test "update does not touch show_counterparty_account when the param is absent" do
    @user.update!(preferences: { "show_counterparty_account" => false })

    patch settings_appearance_path, params: { user: { show_split_grouped: "1" } }

    assert_not @user.reload.show_counterparty_account?
  end
end
