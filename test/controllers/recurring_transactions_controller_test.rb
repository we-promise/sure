require "test_helper"

class RecurringTransactionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @merchant = merchants(:netflix)
    @family.recurring_transactions.destroy_all

    @recurring_transaction = @family.recurring_transactions.create!(
      account: @account,
      merchant: @merchant,
      amount: 15.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 5.days.from_now.to_date,
      status: "active",
      manual: false,
      occurrence_count: 3
    )
  end

  test "destroy dismisses instead of deleting the row" do
    assert_no_difference "RecurringTransaction.count" do
      delete recurring_transaction_path(@recurring_transaction)
    end

    assert_redirected_to recurring_transactions_path
    assert @recurring_transaction.reload.dismissed?
  end

  test "dismissed recurring transaction is absent from index" do
    @recurring_transaction.dismiss!

    get recurring_transactions_path
    assert_response :success
    assert_not_includes assigns(:recurring_transactions), @recurring_transaction
    assert_includes assigns(:dismissed_recurring_transactions), @recurring_transaction
  end

  test "toggle_status 404s for an already-dismissed recurring transaction" do
    @recurring_transaction.dismiss!

    assert_raises(ActiveRecord::RecordNotFound) do
      post toggle_status_recurring_transaction_path(@recurring_transaction)
    end
  end

  test "destroying an already-dismissed recurring transaction 404s" do
    @recurring_transaction.dismiss!

    assert_raises(ActiveRecord::RecordNotFound) do
      delete recurring_transaction_path(@recurring_transaction)
    end
  end

  test "restore undismisses a recurring transaction" do
    @recurring_transaction.dismiss!

    post restore_recurring_transaction_path(@recurring_transaction)

    assert_redirected_to recurring_transactions_path
    assert_not @recurring_transaction.reload.dismissed?
  end

  test "restore respects account access scoping" do
    @recurring_transaction.update!(account: accounts(:investment))
    @recurring_transaction.dismiss!

    sign_in users(:family_member)

    assert_raises(ActiveRecord::RecordNotFound) do
      post restore_recurring_transaction_path(@recurring_transaction)
    end
  end
end
