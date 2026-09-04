require "test_helper"

class RecurringAllocationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    # credit_card is shared read-only with family_member in the fixtures, so
    # this series is visible to them but must never be mutable by them.
    @series = @family.recurring_transactions.create!(
      name: "Card Annual Fee", account: accounts(:credit_card), amount: 95,
      currency: "USD", expected_day_of_month: Date.current.day,
      anchor_date: Date.current, last_occurrence_date: Date.current,
      next_expected_date: Date.current, status: "active", manual: true
    )
    @occurrence = @series.recurring_occurrences.order(:due_on).first
  end

  test "allocation writes redirect when the family has turned recurring transactions off" do
    @family.update!(recurring_transactions_disabled: true)

    post recurring_occurrence_allocations_url(@occurrence), params: { amount: "5.00" }

    assert_redirected_to root_path
    assert_equal 0, @occurrence.reload.allocations.count
  end

  test "a read-only account share cannot record a payment" do
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member

    post recurring_occurrence_allocations_url(@occurrence), params: { amount: "5.00" }

    assert_response :not_found
    assert_equal 0, @occurrence.reload.allocations.count
  end

  test "a read-only account share cannot unlink, confirm or reject an allocation" do
    entry = accounts(:credit_card).entries.create!(
      date: Date.current, amount: 95, currency: "USD", name: "ANNUAL FEE",
      entryable: Transaction.new
    )
    suggestion = RecurringTransaction::Allocator.new(@occurrence).allocate_matched!(
      entry: entry, state: "suggested", confidence: 0.7, signals: { name: 0.35 }
    )

    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member

    post confirm_recurring_allocation_url(suggestion)
    assert_response :not_found
    assert suggestion.reload.allocation_suggested?

    post reject_recurring_allocation_url(suggestion)
    assert_response :not_found
    assert RecurringAllocation.exists?(suggestion.id)

    delete recurring_allocation_url(suggestion)
    assert_response :not_found
    assert RecurringAllocation.exists?(suggestion.id)
  end

  test "the account owner records the same payment" do
    post recurring_occurrence_allocations_url(@occurrence), params: { amount: "5.00" }

    assert_redirected_to bills_url
    assert_equal 5, @occurrence.reload.allocations.sole.allocated_amount
  end

  test "a valid paid_on records the payment on that date" do
    paid = 3.days.ago.to_date

    post recurring_occurrence_allocations_url(@occurrence),
         params: { amount: "5.00", paid_on: paid.iso8601 }

    assert_redirected_to bills_url
    assert_equal paid, @occurrence.reload.allocations.sole.paid_on
  end

  test "a malformed paid_on is rejected instead of being recorded as today" do
    post recurring_occurrence_allocations_url(@occurrence),
         params: { amount: "5.00", paid_on: "not-a-date" }

    assert_redirected_to bills_url
    assert flash[:alert].present?
    assert_equal 0, @occurrence.reload.allocations.count,
      "a nil-cast date would have silently defaulted the payment to today"
  end
end
