require "test_helper"

class InvestmentsControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:investment)
  end

  test "the investment type select is labelled from the locale" do
    get new_investment_url
    assert_response :success
    assert_select "label[for=account_accountable_attributes_subtype]", text: "Investment type"
  end
end
