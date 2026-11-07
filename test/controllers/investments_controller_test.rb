require "test_helper"

class InvestmentsControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:investment)
  end

  test "Saxo is offered in the investment selector when preview is enabled" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    Setting.saxo_app_key = nil
    Setting.saxo_app_secret = nil

    get new_investment_url(step: "method_select")

    assert_response :success
    assert_select "a[href='#{new_saxo_item_path}']", text: /Saxo/
  end

  test "Saxo is hidden in the investment selector when preview is disabled" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get new_investment_url(step: "method_select")

    assert_response :success
    assert_select "a[href='#{new_saxo_item_path}']", count: 0
  end
end
