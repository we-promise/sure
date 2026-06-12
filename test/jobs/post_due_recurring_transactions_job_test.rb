require "test_helper"

class PostDueRecurringTransactionsJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    # Use the generic Test merchant rather than `:netflix` — the
    # `netflix_subscription` fixture already occupies the
    # (family, account, netflix, 15.99, USD) slot under the partial
    # unique index `idx_recurring_txns_acct_merchant`, so a second
    # `create!` with the same combo would PG::UniqueViolation.
    @merchant = merchants(:one)
  end

  def build_recurring(**overrides)
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

  test "posts every active + auto_post + due recurring" do
    due = build_recurring
    also_due = build_recurring(merchant: nil, name: "Gym", amount: 40.0)

    assert_difference -> { Entry.count }, 2 do
      PostDueRecurringTransactionsJob.new.perform
    end

    assert_in_delta Date.current.next_month.beginning_of_month, due.reload.next_expected_date, 31
    assert_in_delta Date.current.next_month.beginning_of_month, also_due.reload.next_expected_date, 31
  end

  test "skips recurring without auto_post flag" do
    build_recurring(auto_post: false)

    assert_no_difference -> { Entry.count } do
      PostDueRecurringTransactionsJob.new.perform
    end
  end

  test "skips inactive recurring even when auto_post is on and date is due" do
    build_recurring(status: "inactive")

    assert_no_difference -> { Entry.count } do
      PostDueRecurringTransactionsJob.new.perform
    end
  end

  test "skips recurring whose next_expected_date is in the future" do
    build_recurring(next_expected_date: 5.days.from_now.to_date)

    assert_no_difference -> { Entry.count } do
      PostDueRecurringTransactionsJob.new.perform
    end
  end

  test "one failing recurring does not break the rest of the batch" do
    good = build_recurring
    bad = build_recurring(merchant: nil, name: "Will explode")

    RecurringTransaction::AutoPoster.any_instance.stubs(:call).raises(StandardError.new("boom")).then.returns(
      RecurringTransaction::AutoPoster::Result.new(status: :posted, entry: nil)
    )

    Sentry.expects(:capture_exception).at_least_once

    assert_nothing_raised do
      PostDueRecurringTransactionsJob.new.perform
    end
  end
end
