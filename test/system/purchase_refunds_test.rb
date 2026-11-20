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

    visit transaction_path(refund)
    assert_selector "summary", text: /Purchase refund/i, count: 1
    assert_selector "details:not([open]) > summary", text: /Manage refund/i
  end

  test "switching to expense clears the refund flag and hides the picker" do
    user = users(:family_admin)
    user.update!(preferences: user.preferences.merge("preview_features_enabled" => true))
    sign_in user

    visit new_transaction_path(nature: "inflow")

    assert_selector "[data-transaction-type-tabs-target='inflowOnly']", visible: true
    find("label[for='entry_refund']").click
    assert_selector "[data-transaction-type-tabs-target='refundFields']", visible: true

    within("form[data-controller~='transaction-type-tabs']") do
      click_on I18n.t("shared.transaction_tabs.expense")
    end

    assert_no_selector "[data-transaction-type-tabs-target='inflowOnly']", visible: true
    assert_not page.find("#entry_refund", visible: :all).checked?

    within("form[data-controller~='transaction-type-tabs']") do
      click_on I18n.t("shared.transaction_tabs.income")
    end

    assert_selector "[data-transaction-type-tabs-target='inflowOnly']", visible: true
    assert_no_selector "[data-transaction-type-tabs-target='refundFields']", visible: true
    assert_not page.find("#entry_refund", visible: :all).checked?
  end

  test "classify a new income entry as a refund and link the purchase" do
    user = users(:family_admin)
    user.update!(preferences: user.preferences.merge("preview_features_enabled" => true))
    sign_in user
    purchase = create_transaction(name: "Ten shirts", amount: 1000, category: categories(:one))

    visit account_url(accounts(:depository), tab: "activity")
    within "[data-testid='activity-menu']" do
      click_on "New"
      click_on "New transaction"
    end
    within("form[data-controller~='transaction-type-tabs']") do
      click_on I18n.t("shared.transaction_tabs.income")
    end

    find("#entry_name").click
    fill_in "entry_name", with: "Two shirts returned"
    # The hotwire combobox submits through its hidden field, which commits on
    # option selection. This test covers the refund flow; the combobox itself
    # has dedicated system coverage, so set the submitted field directly.
    page.execute_script("document.querySelector(\"input[name='entry[name]']\").value = 'Two shirts returned'")
    find_field("entry[amount]").set("200")
    # The money field's operator row floats over the controls below it while
    # the amount is focused; blur it before clicking the toggle.
    page.execute_script("document.activeElement.blur()")
    find("label[for='entry_refund']").click
    select_ds(I18n.t("transactions.form.refund_purchase_label"), purchase)
    click_button I18n.t("transactions.form.submit")
    assert_text I18n.t("transactions.create.created")

    refund = Entry.find_by!(name: "Two shirts returned")
    assert refund.transaction.refund?
    assert_equal purchase.transaction, refund.transaction.refund_of

    visit transaction_path(purchase)
    assert_selector "[data-testid='purchase-net-cost']", text: /800/
  end
end
