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

  test "show hides matching entries from inaccessible accounts" do
    sign_in users(:family_member)

    family = families(:dylan_family)
    accessible_account = accounts(:depository)
    inaccessible_account = accounts(:investment)

    recurring = family.recurring_transactions.create!(
      account: nil,
      name: "Accountless Access Pattern",
      amount: 66.66,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      status: "active",
      occurrence_count: 3,
      manual: true
    )

    accessible_account.entries.create!(
      date: Date.current.beginning_of_month + 4.days,
      amount: 66.66,
      currency: "USD",
      name: "Accountless Access Pattern",
      entryable: Transaction.create!(category: categories(:food_and_drink))
    )

    inaccessible_account.entries.create!(
      date: Date.current.beginning_of_month + 4.days,
      amount: 66.66,
      currency: "USD",
      name: "Accountless Access Pattern",
      entryable: Transaction.create!(category: categories(:food_and_drink))
    )

    get recurring_transaction_url(recurring)

    assert_response :success
    assert_select "p", text: /#{Regexp.escape(accessible_account.name)}/
    assert_select "p", text: /#{Regexp.escape(inaccessible_account.name)}/, count: 0
  end
end
