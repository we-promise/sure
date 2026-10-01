require "application_system_test_case"

class TransactionCurrencyTotalsTest < ApplicationSystemTestCase
  include EntriesTestHelper

  test "a transfer-only day shows a zero total in pounds" do
    user = users(:family_admin)
    user.family.update!(currency: "GBP")
    account = accounts(:depository)
    account.update!(currency: "GBP")
    date = Date.current - 2.days
    create_transaction(account: account, currency: "GBP", amount: 100, date: date, kind: "funds_movement")
    sign_in user

    visit transactions_url(q: { account_ids: [ account.id ], start_date: date.to_s, end_date: date.to_s })

    assert_selector "#entry-group-#{date}-totals", text: "£0.00"
    page.save_screenshot(Rails.root.join("tmp/screenshots/transaction-currency-totals.png"))
  end
end
