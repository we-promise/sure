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

  # Regression: two waypoints landing on the same date (no DB constraint
  # forbids it, only an app-level uniqueness validation a concurrent write
  # could race) must not make latest_flagged_gap key off the date alone —
  # otherwise a later, same-date waypoint that actually resolves the gap
  # could be shadowed by an earlier one on that date that didn't.
  test "a same-date waypoint that resolves the gap is not shadowed by an earlier one on the same date" do
    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: 10.days.ago.to_date, balance: 1000 },
        { type: "reconciliation", date: 6.days.ago.to_date, balance: 1050 },
        { type: "reconciliation", date: 5.days.ago.to_date, balance: 1050 },
        { type: "reconciliation", date: 4.days.ago.to_date, balance: 1050 }
      ]
    )
    # Simulate two Valuation waypoints landing on the same date: the first
    # still shows the gap (1050), the second (inserted right after, so it
    # sorts later via the :id tiebreaker) resolves it (matches the implied
    # balance of 1000 exactly). validate: false bypasses the date-uniqueness
    # validation to construct this otherwise-blocked race.
    account.entries.create!(
      name: "Valuation", date: 3.days.ago.to_date, amount: 1050, currency: "USD",
      entryable: Valuation.new(kind: "reconciliation")
    )
    account.entries.build(
      name: "Valuation", date: 3.days.ago.to_date, amount: 1000, currency: "USD",
      entryable: Valuation.new(kind: "reconciliation")
    ).save!(validate: false)

    assert_nil Balance::IntegrityChecker.new(account).latest_flagged_gap,
      "the same-date waypoint that actually resolves the gap must win, not an earlier one sharing its date"
  end

  # Account.create_and_sync writes a linked account's opening anchor as the
  # balance at link time, dated before the imported history; the provider
  # history then runs forward from it. That anchor is a placeholder, so it
  # must not be read as a waypoint the ledger has to reach.
  test "a linked account's placeholder opening anchor does not create a gap" do
    account = accounts(:connected)
    account.entries.destroy_all
    assert account.linked?, "test requires a linked account"

    [
      { date: 2.years.ago.to_date, amount: 1000, kind: "opening_anchor" },
      { date: 30.days.ago.to_date, amount: -500, kind: nil }, # imported deposit
      { date: 20.days.ago.to_date, amount: 200, kind: nil },  # imported payment
      { date: 5.days.ago.to_date, amount: 1000, kind: "reconciliation" },
      { date: 4.days.ago.to_date, amount: 1000, kind: "reconciliation" },
      { date: 3.days.ago.to_date, amount: 1000, kind: "reconciliation" },
      { date: Date.current, amount: 1000, kind: "current_anchor" }
    ].each do |e|
      account.entries.create!(
        name: "Entry", date: e[:date], amount: e[:amount], currency: account.currency,
        entryable: e[:kind] ? Valuation.new(kind: e[:kind]) : Transaction.new
      )
    end

    assert_nil Balance::IntegrityChecker.new(account).latest_flagged_gap
  end

  test "a linked account still flags a gap that opens between provider-reported balances" do
    account = accounts(:connected)
    account.entries.destroy_all

    [
      { date: 2.years.ago.to_date, amount: 1000, kind: "opening_anchor" },
      { date: 10.days.ago.to_date, amount: 1000, kind: "reconciliation" },
      { date: 5.days.ago.to_date, amount: 1050, kind: "reconciliation" },
      { date: 4.days.ago.to_date, amount: 1050, kind: "reconciliation" },
      { date: 2.days.ago.to_date, amount: 1050, kind: "current_anchor" }
    ].each do |e|
      account.entries.create!(
        name: "Valuation", date: e[:date], amount: e[:amount], currency: account.currency,
        entryable: Valuation.new(kind: e[:kind])
      )
    end

    gap = Balance::IntegrityChecker.new(account).latest_flagged_gap

    assert gap
    assert_equal 10.days.ago.to_date, gap.anchor_waypoint.date
    assert_in_delta 50, gap.difference, 0.01
  end

  # A linked account's reconciliation and current anchor hold the balance the
  # bank reported at the day's sync, not at the end of the day. Transactions
  # booked later that day, dated the same day, are in the ledger but not in
  # the snapshot. On a busy account that differs every day, so the residual
  # never settles even though no transaction is missing.
  test "same-day transactions booked after a linked account's sync do not create a gap" do
    freeze_time
    account = accounts(:connected)
    account.entries.destroy_all

    balance = 1000
    add_linked_entry(account, date: 10.days.ago.to_date, amount: balance, kind: "reconciliation")
    (3..8).reverse_each do |days_ago|
      date = days_ago.days.ago.to_date
      spent = 10 * days_ago
      # Snapshot first, then the day's purchase is booked, dated the same day.
      add_linked_entry(account, date: date, amount: balance, kind: "reconciliation")
      add_linked_entry(account, date: date, amount: spent)
      balance -= spent
    end
    # Quiet days at the end: the snapshots are exact again.
    add_linked_entry(account, date: 2.days.ago.to_date, amount: balance, kind: "reconciliation")
    add_linked_entry(account, date: 1.day.ago.to_date, amount: balance, kind: "current_anchor")

    assert_empty Balance::IntegrityChecker.new(account).flagged_gaps
  end

  test "a missing transaction on a busy linked account is still flagged" do
    freeze_time
    account = accounts(:connected)
    account.entries.destroy_all

    add_linked_entry(account, date: 10.days.ago.to_date, amount: 1000, kind: "reconciliation")
    # The bank received a 50 deposit (day 9) that was never imported.
    # Day 8: snapshot taken before the day's purchase was booked.
    add_linked_entry(account, date: 8.days.ago.to_date, amount: 1050, kind: "reconciliation")
    add_linked_entry(account, date: 8.days.ago.to_date, amount: 30)
    add_linked_entry(account, date: 6.days.ago.to_date, amount: 1020, kind: "reconciliation")
    add_linked_entry(account, date: 5.days.ago.to_date, amount: 1020, kind: "reconciliation")
    add_linked_entry(account, date: 4.days.ago.to_date, amount: 1020, kind: "reconciliation")
    add_linked_entry(account, date: 4.days.ago.to_date, amount: 15)
    add_linked_entry(account, date: 2.days.ago.to_date, amount: 1005, kind: "current_anchor")

    gap = Balance::IntegrityChecker.new(account).latest_flagged_gap

    assert gap
    assert_equal 10.days.ago.to_date, gap.anchor_waypoint.date
    assert_equal 8.days.ago.to_date, gap.first_open_waypoint.date
    assert_equal 2.days.ago.to_date, gap.latest_waypoint.date
    assert_in_delta 50, gap.difference, 0.01
  end

  test "a missing transaction smaller than a busy day's activity is flagged on the next exact snapshot" do
    freeze_time
    account = accounts(:connected)
    account.entries.destroy_all

    add_linked_entry(account, date: 10.days.ago.to_date, amount: 1000, kind: "reconciliation")
    # A 25 deposit (day 9) was never imported. Day 8's snapshot already has
    # the day's 30 purchase, so its residual (25) looks like timing.
    add_linked_entry(account, date: 8.days.ago.to_date, amount: 995, kind: "reconciliation")
    add_linked_entry(account, date: 8.days.ago.to_date, amount: 30)
    add_linked_entry(account, date: 6.days.ago.to_date, amount: 995, kind: "reconciliation")
    add_linked_entry(account, date: 5.days.ago.to_date, amount: 995, kind: "reconciliation")
    add_linked_entry(account, date: 3.days.ago.to_date, amount: 995, kind: "current_anchor")

    gap = Balance::IntegrityChecker.new(account).latest_flagged_gap

    assert gap
    assert_equal 10.days.ago.to_date, gap.anchor_waypoint.date
    assert_equal 6.days.ago.to_date, gap.first_open_waypoint.date
    assert_in_delta 25, gap.difference, 0.01
  end

  test "busy days between exact snapshots neither hide nor move an open gap" do
    freeze_time
    account = accounts(:connected)
    account.entries.destroy_all

    add_linked_entry(account, date: 12.days.ago.to_date, amount: 1000, kind: "reconciliation")
    # A 40 deposit (day 11) was never imported. Day 10 is quiet, every later
    # sync day has 50 of purchases booked after the snapshot.
    add_linked_entry(account, date: 10.days.ago.to_date, amount: 1040, kind: "reconciliation")
    balance = 1040
    (3..9).reverse_each do |days_ago|
      add_linked_entry(account, date: days_ago.days.ago.to_date, amount: balance, kind: "reconciliation")
      add_linked_entry(account, date: days_ago.days.ago.to_date, amount: 50)
      balance -= 50
    end
    add_linked_entry(account, date: 2.days.ago.to_date, amount: balance, kind: "current_anchor")
    add_linked_entry(account, date: 2.days.ago.to_date, amount: 50)

    gap = Balance::IntegrityChecker.new(account).latest_flagged_gap

    assert gap, "a gap open since an exact snapshot must stay open across busy days"
    assert_equal 10.days.ago.to_date, gap.first_open_waypoint.date
    assert_equal 2.days.ago.to_date, gap.latest_waypoint.date
    assert_in_delta 40, gap.difference, 0.01
  end

  test "a day with only pending transactions is not an exact snapshot" do
    freeze_time
    account = accounts(:connected)
    account.entries.destroy_all

    add_linked_entry(account, date: 8.days.ago.to_date, amount: 1000, kind: "reconciliation")
    # The bank's snapshots include a 20 card authorization the ledger leaves
    # out while it is pending.
    (3..6).reverse_each do |days_ago|
      add_linked_entry(account, date: days_ago.days.ago.to_date, amount: 980, kind: "reconciliation")
    end
    (3..6).each do |days_ago|
      account.entries.create!(
        name: "Card hold", date: days_ago.days.ago.to_date, amount: 20, currency: account.currency,
        entryable: Transaction.new(extra: { "plaid" => { "pending" => true } })
      )
    end

    assert_nil Balance::IntegrityChecker.new(account).latest_flagged_gap
  end

  test "linked liability accounts read late charges with the liability sign" do
    freeze_time
    account = create_account_with_ledger(
      account: { type: CreditCard, currency: "USD" },
      entries: [
        { type: "reconciliation", date: 10.days.ago.to_date, balance: 500 },
        # Each snapshot is taken before that day's 40 charge is booked.
        *(5..8).flat_map do |days_ago|
          [
            { type: "reconciliation", date: days_ago.days.ago.to_date, balance: 500 + 40 * (8 - days_ago) },
            { type: "transaction", date: days_ago.days.ago.to_date, amount: 40 }
          ]
        end,
        { type: "reconciliation", date: 3.days.ago.to_date, balance: 660 }
      ]
    )
    Balance::IntegrityChecker.any_instance.stubs(:linked?).returns(true)

    assert_empty Balance::IntegrityChecker.new(account).flagged_gaps
  end

  test "a gap that opens on a busy day reports only the part the day's activity cannot explain" do
    freeze_time
    account = accounts(:connected)
    account.entries.destroy_all

    add_linked_entry(account, date: 8.days.ago.to_date, amount: 1000, kind: "reconciliation")
    # A 50 deposit (day 7) was never imported, and every later sync day has a
    # purchase booked after the snapshot, so no exact snapshot follows.
    ledger = 1000
    { 5 => 100, 4 => 10, 3 => 10, 2 => 10 }.each do |days_ago, purchase|
      add_linked_entry(account, date: days_ago.days.ago.to_date, amount: ledger + 50, kind: "reconciliation")
      add_linked_entry(account, date: days_ago.days.ago.to_date, amount: purchase)
      ledger -= purchase
    end

    gap = Balance::IntegrityChecker.new(account).latest_flagged_gap

    assert gap
    assert_equal 5.days.ago.to_date, gap.first_open_waypoint.date
    assert_in_delta 50, gap.difference, 0.01, "the 100 purchase booked after day 5's sync is timing, not part of the gap"
  end

  private
    def add_linked_entry(account, date:, amount:, kind: nil)
      account.entries.create!(
        name: kind ? "Valuation" : "Purchase", date: date, amount: amount, currency: account.currency,
        entryable: kind ? Valuation.new(kind: kind) : Transaction.new
      )
    end
end
