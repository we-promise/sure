require "test_helper"

class InvestmentsControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:investment)
  end

  test "physical gold edit dialog stays open when its backdrop is clicked" do
    @account.holdings.destroy_all
    @account.investment.update!(subtype: "gold")

    get edit_investment_path(@account)

    assert_response :success
    assert_select "dialog[data-ds--dialog-disable-click-outside-value='true']"
  end
end
