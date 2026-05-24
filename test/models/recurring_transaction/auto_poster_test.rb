require "test_helper"

class RecurringTransaction::AutoPosterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    # `merchants(:netflix)` collides with the `netflix_subscription`
    # recurring fixture on the partial unique index
    # `idx_recurring_txns_acct_merchant`
    # (family_id, account_id, merchant_id, amount, currency).
    # `merchants(:one)` is the generic Test merchant — unused by any
    # recurring fixture — so the helper's `create!` doesn't violate
    # the index.
    @merchant = merchants(:one)
  end

  def build_due_recurring(**overrides)
    @family.recurring_transactions.create!({
      account: @account,
      merchant: @merchant,
      amount: 15.99,
      currency: "USD",
      expected_day_of_month: Date.current.day,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: Date.current,
      status: "active",
      occurrence_count: 1,
      auto_post: true
    }.merge(overrides))
  end

  test "posts a real entry for an active, due, non-transfer recurring" do
    recurring = build_due_recurring

    result = nil
    assert_difference -> { @account.entries.count }, 1 do
      result = RecurringTransaction::AutoPoster.new(recurring).call
    end

    assert result.posted?
    assert_equal Date.current, result.entry.date
    assert_equal "USD", result.entry.currency
    assert_equal 15.99, result.entry.amount.to_d
    assert_equal "recurring_auto_post", result.entry.source
    assert_kind_of Transaction, result.entry.entryable
  end

  # Provider syncs (Plaid / SimpleFIN / etc.) treat `user_modified` entries as
  # protected and skip reconciliation. Auto-posted entries are system-generated,
  # not user-edited — they must stay reconcilable so the same transaction can
  # be claimed by a provider import later (#1080 review feedback).
  test "auto-posted entry is not marked user_modified" do
    recurring = build_due_recurring

    result = RecurringTransaction::AutoPoster.new(recurring).call

    assert result.posted?
    assert_not result.entry.user_modified?
    assert_not result.entry.protected_from_sync?
  end

  test "advances next_expected_date after posting so the row is no longer due" do
    recurring = build_due_recurring
    original_next = recurring.next_expected_date

    RecurringTransaction::AutoPoster.new(recurring).call
    recurring.reload

    assert_operator recurring.next_expected_date, :>, original_next
    assert_equal 2, recurring.occurrence_count
  end

  test "skips inactive recurring" do
    recurring = build_due_recurring(status: "inactive")

    result = nil
    assert_no_difference -> { @account.entries.count } do
      result = RecurringTransaction::AutoPoster.new(recurring).call
    end

    assert_not result.posted?
    assert_equal :skipped_inactive, result.status
  end

  test "skips recurring whose next_expected_date is still in the future" do
    recurring = build_due_recurring(next_expected_date: 1.week.from_now.to_date)

    result = nil
    assert_no_difference -> { @account.entries.count } do
      result = RecurringTransaction::AutoPoster.new(recurring).call
    end

    assert_not result.posted?
    assert_equal :skipped_not_due, result.status
  end

  test "skips recurring with no source account" do
    # `account` is optional on RecurringTransaction (the DB-level
    # check_constraint only requires it when destination_account_id is
    # set), so the AutoPoster needs to handle a nil account explicitly
    # rather than NoMethodError on @recurring.account.entries.
    recurring = build_due_recurring(account: nil)

    result = nil
    assert_no_difference -> { Entry.count } do
      result = RecurringTransaction::AutoPoster.new(recurring).call
    end

    assert_not result.posted?
    assert_equal :skipped_no_account, result.status
  end

  test "skips transfers in V1" do
    other_account = accounts(:credit_card)
    recurring = build_due_recurring(
      destination_account: other_account,
      merchant: nil,
      name: "Monthly card payment"
    )

    result = nil
    assert_no_difference -> { @account.entries.count } do
      result = RecurringTransaction::AutoPoster.new(recurring).call
    end

    assert_not result.posted?
    assert_equal :skipped_transfer, result.status
  end

  test "uses expected_amount_avg for manual recurring with variance" do
    recurring = build_due_recurring(
      manual: true,
      amount: 20.0,
      expected_amount_min: 18.0,
      expected_amount_max: 22.0,
      expected_amount_avg: 19.5
    )

    result = RecurringTransaction::AutoPoster.new(recurring).call

    assert result.posted?
    assert_equal 19.5, result.entry.amount.to_d
  end

  # Edge case: a manual recurring that has `auto_post: true` flipped on
  # before its first posted occurrence will still have `expected_amount_avg`
  # nil (the running average is seeded by `record_occurrence!` from real
  # transactions, not from the template). `posting_amount` must fall back
  # to the template `amount` rather than blowing up on nil arithmetic
  # inside Money#initialize.
  test "manual recurring with nil expected_amount_avg falls back to template amount" do
    recurring = build_due_recurring(
      manual: true,
      amount: 12.34,
      expected_amount_avg: nil
    )

    result = RecurringTransaction::AutoPoster.new(recurring).call

    assert result.posted?
    assert_equal 12.34, result.entry.amount.to_d
  end

  test "second call in the same day skips because next_expected_date is now in the future" do
    recurring = build_due_recurring

    first = RecurringTransaction::AutoPoster.new(recurring).call
    assert first.posted?

    recurring.reload
    second = RecurringTransaction::AutoPoster.new(recurring).call
    assert_not second.posted?
    assert_equal :skipped_not_due, second.status
  end
end
