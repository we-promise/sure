require "test_helper"

class RecurringTransaction::IdentifierTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @identifier = RecurringTransaction::Identifier.new(@family)
    @family.recurring_transactions.destroy_all
  end

  test "identifies recurring pattern with transactions on similar days mid-month" do
    account = @family.accounts.first
    merchant = merchants(:netflix)

    # Create 3 transactions on days 5, 6, 7 (clearly clustered)
    [ 5, 6, 7 ].each_with_index do |day, i|
      transaction = Transaction.create!(
        merchant: merchant,
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: i.months.ago.beginning_of_month + (day - 1).days,
        amount: 15.99,
        currency: "USD",
        name: "Netflix Subscription",
        entryable: transaction
      )
    end

    patterns_count = @identifier.identify_recurring_patterns

    assert_equal 1, patterns_count
    assert_equal 1, @family.recurring_transactions.count

    recurring = @family.recurring_transactions.first
    assert_equal merchant, recurring.merchant
    assert_equal 15.99, recurring.amount
    assert_in_delta 6, recurring.expected_day_of_month, 1  # Should be around day 6
  end

  test "identifies recurring pattern with transactions wrapping month boundary" do
    account = @family.accounts.first
    merchant = merchants(:netflix)

    # Create 3 transactions on days 30, 31, 1 (wraps around month boundary)
    dates = [
      2.months.ago.end_of_month - 1.day,  # Day 30
      1.month.ago.end_of_month,           # Day 31
      Date.current.beginning_of_month     # Day 1
    ]

    dates.each do |date|
      transaction = Transaction.create!(
        merchant: merchant,
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: date,
        amount: 15.99,
        currency: "USD",
        name: "Netflix Subscription",
        entryable: transaction
      )
    end

    patterns_count = @identifier.identify_recurring_patterns

    assert_equal 1, patterns_count, "Should identify pattern wrapping month boundary"
    assert_equal 1, @family.recurring_transactions.count

    recurring = @family.recurring_transactions.first
    assert_equal merchant, recurring.merchant
    assert_equal 15.99, recurring.amount
    # Add validation that expected_day is near 31 or 1, not mid-month
    assert_includes [ 30, 31, 1 ], recurring.expected_day_of_month,
      "Expected day should be near month boundary (30, 31, or 1), not mid-month. Got: #{recurring.expected_day_of_month}"
  end

  test "identifies recurring pattern with transactions spanning end and start of month" do
    account = @family.accounts.first
    merchant = merchants(:netflix)

    # Create 3 transactions on days 28, 29, 30, 31, 1, 2 (should cluster with circular distance)
    dates = [
      3.months.ago.end_of_month - 3.days,  # Day 28
      2.months.ago.end_of_month - 2.days,  # Day 29
      2.months.ago.end_of_month - 1.day,   # Day 30
      1.month.ago.end_of_month,            # Day 31
      Date.current.beginning_of_month,     # Day 1
      Date.current.beginning_of_month + 1.day  # Day 2
    ]

    dates.each do |date|
      transaction = Transaction.create!(
        merchant: merchant,
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: date,
        amount: 15.99,
        currency: "USD",
        name: "Netflix Subscription",
        entryable: transaction
      )
    end

    patterns_count = @identifier.identify_recurring_patterns

    assert_equal 1, patterns_count, "Should identify pattern with circular clustering at month boundary"
    assert_equal 1, @family.recurring_transactions.count

    recurring = @family.recurring_transactions.first
    assert_equal merchant, recurring.merchant
    assert_equal 15.99, recurring.amount
    # Validate expected_day falls within the cluster range (28-31 or 1-2), not an outlier like day 15
    assert_includes (28..31).to_a + [ 1, 2 ], recurring.expected_day_of_month,
      "Expected day should be within cluster range (28-31 or 1-2), not mid-month. Got: #{recurring.expected_day_of_month}"
  end

  test "does not identify pattern when days are not clustered" do
    account = @family.accounts.first
    merchant = merchants(:netflix)

    # Create 3 transactions on days 1, 15, 30 (widely spread, should not cluster)
    [ 1, 15, 30 ].each_with_index do |day, i|
      transaction = Transaction.create!(
        merchant: merchant,
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: i.months.ago.beginning_of_month + (day - 1).days,
        amount: 15.99,
        currency: "USD",
        name: "Netflix Subscription",
        entryable: transaction
      )
    end

    patterns_count = @identifier.identify_recurring_patterns

    assert_equal 0, patterns_count
    assert_equal 0, @family.recurring_transactions.count
  end

  test "does not identify pattern with fewer than 3 occurrences" do
    account = @family.accounts.first
    merchant = merchants(:netflix)

    # Create only 2 transactions
    [ 5, 6 ].each_with_index do |day, i|
      transaction = Transaction.create!(
        merchant: merchant,
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: i.months.ago.beginning_of_month + (day - 1).days,
        amount: 15.99,
        currency: "USD",
        name: "Netflix Subscription",
        entryable: transaction
      )
    end

    patterns_count = @identifier.identify_recurring_patterns

    assert_equal 0, patterns_count
    assert_equal 0, @family.recurring_transactions.count
  end

  test "updates existing recurring transaction when pattern is found again" do
    account = @family.accounts.first
    merchant = merchants(:amazon)  # Use different merchant to avoid fixture conflicts

    # Create initial recurring transaction
    existing = @family.recurring_transactions.create!(
      merchant: merchant,
      amount: 29.99,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: 2.months.ago.to_date,
      next_expected_date: 1.month.ago.to_date,
      occurrence_count: 2,
      status: "active"
    )

    # Create 3 new transactions on similar clustered days
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        merchant: merchant,
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 14.days,  # Day 15
        amount: 29.99,
        currency: "USD",
        name: "Amazon Purchase",
        entryable: transaction
      )
    end

    assert_no_difference "@family.recurring_transactions.count" do
      @identifier.identify_recurring_patterns
    end

    recurring = @family.recurring_transactions.first
    assert_equal existing.id, recurring.id, "Should update existing recurring transaction"
    assert_equal "active", recurring.status
    # Verify last_occurrence_date was updated
    assert recurring.last_occurrence_date >= 2.months.ago.to_date
  end

  test "circular_distance calculates correct distance for days near month boundary" do
    # Test wrapping: day 31 to day 1 should be distance 1 (31 -> 1 is one day forward)
    distance = @identifier.send(:circular_distance, 31, 1)
    assert_equal 1, distance

    # Test wrapping: day 1 to day 31 should also be distance 1 (wraps backward)
    distance = @identifier.send(:circular_distance, 1, 31)
    assert_equal 1, distance

    # Test wrapping: day 30 to day 2 should be distance 3 (30->31->1->2 = 3 steps)
    distance = @identifier.send(:circular_distance, 30, 2)
    assert_equal 3, distance

    # Test non-wrapping: day 15 to day 10 should be distance 5
    distance = @identifier.send(:circular_distance, 15, 10)
    assert_equal 5, distance

    # Test same day: distance should be 0
    distance = @identifier.send(:circular_distance, 15, 15)
    assert_equal 0, distance
  end

  test "days_cluster_together returns true for days wrapping month boundary" do
    # Days 29, 30, 31, 1, 2 should cluster (circular distance)
    days = [ 29, 30, 31, 1, 2 ]
    assert @identifier.send(:days_cluster_together?, days), "Should cluster with circular distance"
  end

  test "days_cluster_together returns true for consecutive mid-month days" do
    days = [ 10, 11, 12, 13 ]
    assert @identifier.send(:days_cluster_together?, days)
  end

  test "days_cluster_together returns false for widely spread days" do
    days = [ 1, 15, 30 ]
    assert_not @identifier.send(:days_cluster_together?, days)
  end
end
