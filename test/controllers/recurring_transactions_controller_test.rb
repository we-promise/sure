require "test_helper"

class RecurringTransactionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    @recurring = recurring_transactions(:netflix_subscription)
  end

  test "toggle_auto_post flips the flag and shows a flash" do
    assert_not @recurring.auto_post?

    post toggle_auto_post_recurring_transaction_url(@recurring)

    assert_redirected_to recurring_transactions_path
    assert_equal I18n.t("recurring_transactions.auto_post_enabled"), flash[:notice]
    assert @recurring.reload.auto_post?

    post toggle_auto_post_recurring_transaction_url(@recurring)

    assert_redirected_to recurring_transactions_path
    assert_equal I18n.t("recurring_transactions.auto_post_disabled"), flash[:notice]
    assert_not @recurring.reload.auto_post?
  end

  test "toggle_auto_post is scoped to current family — cannot toggle another family's recurring" do
    other_family = families(:empty)
    other_account = other_family.accounts.create!(
      name: "Other depository", balance: 0, currency: "USD", accountable: Depository.new
    )
    other_recurring = other_family.recurring_transactions.create!(
      account: other_account,
      merchant: merchants(:netflix),
      amount: 1.0,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 1.month.from_now.to_date,
      status: "active",
      occurrence_count: 1
    )

    assert_raises(ActiveRecord::RecordNotFound) do
      post toggle_auto_post_recurring_transaction_url(other_recurring)
    end
  end
end
