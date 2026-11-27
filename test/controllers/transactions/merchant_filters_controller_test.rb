require "test_helper"

class Transactions::MerchantFiltersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "lists the family's merchants and checks the selected ones" do
    get transactions_merchant_filter_url(merchants: [ "Amazon" ])

    assert_response :success
    assert_select "turbo-frame#merchant_filter_options" do
      assert_select "input[type=checkbox][name='q[merchants][]'][value=?][checked]", "Amazon"
      assert_select "input[type=checkbox][name='q[merchants][]'][value=?]:not([checked])", Merchant::NO_MERCHANT_FILTER_VALUE
    end
  end
end
