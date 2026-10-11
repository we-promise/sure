require "test_helper"

# Verify native currency totals through the authenticated transaction response.
class TransactionCurrencyTotalsTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  # Verify the activity response preserves GBP after transfer exclusion empties a day.
  test "transfer-only daily total displays the transaction currency" do
    user = users(:family_admin)
    user.family.update!(currency: "GBP")
    account = accounts(:depository)
    account.update!(currency: "GBP")
    date = Date.current - 2.days
    create_transaction(account: account, currency: "GBP", amount: 100, date: date, kind: "funds_movement")
    sign_in user

    get transactions_url, params: { q: { account_ids: [ account.id ], start_date: date.to_s, end_date: date.to_s } }

    assert_response :success
    assert_select "#entry-group-#{date}-totals", text: "£0.00"
  end
end
