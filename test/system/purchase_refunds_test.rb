require "application_system_test_case"

class PurchaseRefundsTest < ApplicationSystemTestCase
  include EntriesTestHelper

  test "mark a partial refund and see the final purchase cost" do
    user = users(:family_admin)
    user.update!(preferences: user.preferences.merge("preview_features_enabled" => true))
    sign_in user
    purchase = create_transaction(name: "Ten shirts", amount: 1000, category: categories(:one))
    refund = create_transaction(name: "Eight shirts returned", amount: -800)

    visit new_transaction_refund_path(refund)
    select find("option[value='#{purchase.id}']").text, from: "Original purchase"
    click_button "Save refund"
    assert_text "Refund saved"

    visit transaction_path(purchase)
    assert_selector "[data-testid='purchase-net-cost']", text: /200/
    assert_text "Eight shirts returned"
  end
end
