require "test_helper"

class Balance::IntegrityCheckerTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  test "clean account with no gap returns no flagged gaps" do
    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: 10.days.ago.to_date, balance: 1000 },
        { type: "transaction", date: 5.days.ago.to_date, amount: -100 },
        { type: "reconciliation", date: 3.days.ago.to_date, balance: 1100 }
      ]
    )

    assert_empty Balance::IntegrityChecker.new(account).flagged_gaps
  end

  test "a real, persistent gap is flagged only once it has been open longer than MIN_DAYS_OPEN" do
    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: 10.days.ago.to_date, balance: 1000 },
        # Bank silently adds 50 that never gets imported as a transaction.
        { type: "reconciliation", date: 5.days.ago.to_date, balance: 1050 },
        { type: "reconciliation", date: 4.days.ago.to_date, balance: 1050 },
        { type: "reconciliation", date: 3.days.ago.to_date, balance: 1050 },
        { type: "reconciliation", date: 2.days.ago.to_date, balance: 1050 }
      ]
    )

    checker = Balance::IntegrityChecker.new(account)
    gap = checker.latest_flagged_gap

    assert gap
    assert_equal 5.days.ago.to_date, gap.first_open_waypoint.date
    assert_in_delta 50, gap.difference, 0.01

    # Not yet flagged on the very first day the gap appears.
    short_checker = Balance::IntegrityChecker.new(account)
    first_gap_waypoint_date = 5.days.ago.to_date
    assert_not short_checker.flagged_gaps.any? { |g| g.latest_waypoint.date == first_gap_waypoint_date }
  end

  test "a self-resolving one-day outlier is never flagged" do
    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: 10.days.ago.to_date, balance: 1000 },
        # A pending-timing blip that reverses itself the next day.
        { type: "reconciliation", date: 5.days.ago.to_date, balance: 1000 - 6547 },
        { type: "reconciliation", date: 4.days.ago.to_date, balance: 1000 },
        { type: "reconciliation", date: 3.days.ago.to_date, balance: 1000 },
        { type: "reconciliation", date: 2.days.ago.to_date, balance: 1000 }
      ]
    )

    assert_nil Balance::IntegrityChecker.new(account).latest_flagged_gap
  end

  test "split transactions are handled correctly via excluding_split_parents" do
    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: 10.days.ago.to_date, balance: 1000 },
        { type: "transaction", date: 5.days.ago.to_date, amount: -100 }
      ]
    )

    parent_entry = account.entries.find_by!(date: 5.days.ago.to_date)
    parent_entry.update!(excluded: true)
    account.entries.create!(
      name: "Split 1", date: 5.days.ago.to_date, amount: -60, currency: "USD",
      entryable: Transaction.new, parent_entry: parent_entry
    )
    account.entries.create!(
      name: "Split 2", date: 5.days.ago.to_date, amount: -40, currency: "USD",
      entryable: Transaction.new, parent_entry: parent_entry
    )
    account.entries.create!(
      name: "Valuation", date: 3.days.ago.to_date, amount: 1100, currency: "USD",
      entryable: Valuation.new(kind: "reconciliation")
    )
    account.entries.create!(
      name: "Valuation", date: 2.days.ago.to_date, amount: 1100, currency: "USD",
      entryable: Valuation.new(kind: "reconciliation")
    )
    account.entries.create!(
      name: "Valuation", date: 1.day.ago.to_date, amount: 1100, currency: "USD",
      entryable: Valuation.new(kind: "reconciliation")
    )

    assert_nil Balance::IntegrityChecker.new(account).latest_flagged_gap
  end

  test "excluded (non-split) transactions still count toward the flow" do
    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: 10.days.ago.to_date, balance: 1000 },
        { type: "transaction", date: 5.days.ago.to_date, amount: -100 }
      ]
    )
    account.entries.find_by!(date: 5.days.ago.to_date).update!(excluded: true)
    [ 3, 2, 1 ].each do |n|
      account.entries.create!(
        name: "Valuation", date: n.days.ago.to_date, amount: 1100, currency: "USD",
        entryable: Valuation.new(kind: "reconciliation")
      )
    end

    assert_nil Balance::IntegrityChecker.new(account).latest_flagged_gap
  end

  test "liability accounts (credit card) use the inverse sign convention" do
    account = create_account_with_ledger(
      account: { type: CreditCard, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: 10.days.ago.to_date, balance: 500 },
        # 100 of debt appears that was never imported as a transaction.
        { type: "reconciliation", date: 5.days.ago.to_date, balance: 600 },
        { type: "reconciliation", date: 4.days.ago.to_date, balance: 600 },
        { type: "reconciliation", date: 3.days.ago.to_date, balance: 600 },
        { type: "reconciliation", date: 2.days.ago.to_date, balance: 600 }
      ]
    )

    gap = Balance::IntegrityChecker.new(account).latest_flagged_gap

    assert gap
    assert_in_delta 100, gap.difference, 0.01
  end

  test "MIN_DAYS_OPEN boundary: exactly at the threshold is not yet flagged" do
    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: 10.days.ago.to_date, balance: 1000 },
        { type: "reconciliation", date: 5.days.ago.to_date, balance: 1050 },
        { type: "reconciliation", date: 3.days.ago.to_date, balance: 1050 }
      ]
    )

    # (3.days.ago - 5.days.ago) == 2 == MIN_DAYS_OPEN, strictly-greater-than required.
    checker = Balance::IntegrityChecker.new(account, min_days_open: 2)
    assert_nil checker.latest_flagged_gap
  end

  test "MIN_DAYS_OPEN boundary: just past the threshold is flagged" do
    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: 10.days.ago.to_date, balance: 1000 },
        { type: "reconciliation", date: 5.days.ago.to_date, balance: 1050 },
        { type: "reconciliation", date: 2.days.ago.to_date, balance: 1050 }
      ]
    )

    checker = Balance::IntegrityChecker.new(account, min_days_open: 2)
    gap = checker.latest_flagged_gap
    assert gap
    assert_equal 5.days.ago.to_date, gap.first_open_waypoint.date
  end

  test "account with zero or one waypoint returns no gaps without raising" do
    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: []
    )
    assert_empty Balance::IntegrityChecker.new(account).flagged_gaps

    account_with_one = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: 3.days.ago.to_date, balance: 1000 }
      ]
    )
    assert_empty Balance::IntegrityChecker.new(account_with_one).flagged_gaps
  end

  test "flagged_gaps can hold multiple entries for the same ongoing gap, but latest_flagged_gap returns the current one" do
    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: 10.days.ago.to_date, balance: 1000 },
        { type: "reconciliation", date: 6.days.ago.to_date, balance: 1050 },
        { type: "reconciliation", date: 5.days.ago.to_date, balance: 1050 },
        { type: "reconciliation", date: 4.days.ago.to_date, balance: 1050 },
        { type: "reconciliation", date: 3.days.ago.to_date, balance: 1050 },
        { type: "reconciliation", date: 2.days.ago.to_date, balance: 1050 }
      ]
    )

    checker = Balance::IntegrityChecker.new(account)
    gaps = checker.flagged_gaps

    assert_operator gaps.size, :>, 1
    latest = checker.latest_flagged_gap
    assert_equal 2.days.ago.to_date, latest.latest_waypoint.date
  end

  test "a resolved gap returns nil from latest_flagged_gap even though flagged_gaps still has historical entries" do
    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: 10.days.ago.to_date, balance: 1000 },
        { type: "reconciliation", date: 6.days.ago.to_date, balance: 1050 },
        { type: "reconciliation", date: 5.days.ago.to_date, balance: 1050 },
        { type: "reconciliation", date: 4.days.ago.to_date, balance: 1050 },
        { type: "reconciliation", date: 3.days.ago.to_date, balance: 1050 },
        # User finds and enters the missing transaction; the books catch up
        # to the balance the bank has been reporting all along.
        { type: "transaction", date: 2.days.ago.to_date, amount: -50 },
        { type: "reconciliation", date: 1.day.ago.to_date, balance: 1050 }
      ]
    )

    checker = Balance::IntegrityChecker.new(account)

    assert_operator checker.flagged_gaps.size, :>, 0, "historical gap entries should still exist"
    assert_nil checker.latest_flagged_gap, "the gap resolved, so the current state must show nil"
  end

  test "irregular waypoint spacing does not crash and still computes sensible days_open" do
    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: 20.days.ago.to_date, balance: 1000 },
        { type: "reconciliation", date: 10.days.ago.to_date, balance: 1050 },
        { type: "reconciliation", date: 2.days.ago.to_date, balance: 1050 }
      ]
    )

    gap = Balance::IntegrityChecker.new(account).latest_flagged_gap
    assert gap
    assert_equal 10.days.ago.to_date, gap.first_open_waypoint.date
    assert_equal 8, (gap.latest_waypoint.date - gap.first_open_waypoint.date).to_i
  end
end
