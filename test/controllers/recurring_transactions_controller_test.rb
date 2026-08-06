require "test_helper"

class RecurringTransactionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @recurring = recurring_transactions(:netflix_subscription)
  end

  test "show renders recurring detail for accessible pattern" do
    get recurring_transaction_url(@recurring)

    assert_response :success
    assert_select "h1", text: @recurring.display_name
  end

  test "show returns not found for another family recurring" do
    other = families(:empty)
    other_account = other.accounts.create!(
      name: "Other Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    other_recurring = other.recurring_transactions.create!(
      account: other_account,
      name: "Other Sub",
      amount: 10,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      status: "active",
      occurrence_count: 1,
      manual: true
    )

    get recurring_transaction_url(other_recurring)
    assert_response :not_found
  end
end
