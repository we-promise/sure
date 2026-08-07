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

  # Pins the security contract from the earlier route fix. The
  # toggle_auto_post route is post-only specifically because GET-accessible
  # state-changing endpoints are a CSRF / accidental-trigger risk. If
  # someone later loosens the route back to `match via: [:get, :post]`
  # this test catches the regression.
  #
  # Asserts a 404 response rather than `assert_raises ActionController::RoutingError`:
  # in `ActionDispatch::IntegrationTest` the routing error is raised inside
  # `RouteSet` and then caught by the exceptions middleware, which renders
  # a 404. Asserting the raise only passes in dev-mode behavior and would
  # silently pass for the wrong reason here.
  test "toggle_auto_post does not respond to GET" do
    get toggle_auto_post_recurring_transaction_url(@recurring)
    assert_response :not_found
    assert_not @recurring.reload.auto_post?
  end

  test "toggle_auto_post refuses to enable on a transfer recurring" do
    other_account = accounts(:credit_card)
    transfer_recurring = @recurring.family.recurring_transactions.create!(
      account: @recurring.account,
      destination_account: other_account,
      merchant: nil,
      name: "Monthly card payment",
      amount: 100.0,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 1.month.from_now.to_date,
      status: "active",
      occurrence_count: 1
    )

    post toggle_auto_post_recurring_transaction_url(transfer_recurring)

    assert_redirected_to recurring_transactions_path
    assert_equal I18n.t("recurring_transactions.auto_post_transfer_not_allowed"), flash[:alert]
    assert_not transfer_recurring.reload.auto_post?
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

    # `StoreLocation` (included via ApplicationController) globally
    # rescues `ActiveRecord::RecordNotFound` and renders `head :not_found`,
    # so the exception never bubbles to the test. Assert the rendered
    # response instead.
    post toggle_auto_post_recurring_transaction_url(other_recurring)
    assert_response :not_found
    assert_not other_recurring.reload.auto_post?
  end
end
