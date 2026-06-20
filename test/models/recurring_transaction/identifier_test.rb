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
      account: account,
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

  test "identifies name patterns without per-pattern recurring transaction lookups" do
    account = @family.accounts.first
    names = Array.new(4) { |index| "Performance Subscription #{index}" }

    names.each_with_index do |name, index|
      create_name_pattern_entries(
        account: account,
        name: name,
        amount: 40 + index,
        day: 5
      )
    end

    queries = capture_sql_queries do
      assert_equal names.size, @identifier.identify_recurring_patterns
    end

    recurring_lookup_queries = queries.grep(
      /SELECT "recurring_transactions"\.\* FROM "recurring_transactions" WHERE .*"recurring_transactions"\."name" = .*LIMIT/
    )

    assert_empty recurring_lookup_queries
    assert_equal names.size, @family.recurring_transactions.where(name: names).count
  end

  test "keeps automatic recurring lookup amount-scoped" do
    account = @family.accounts.first
    name = "Tiered Performance Subscription"

    recurring_transactions = [ 40, 55 ].map do |amount|
      create_name_pattern_entries(
        account: account,
        name: name,
        amount: amount,
        day: 5
      )

      @family.recurring_transactions.create!(
        account: account,
        name: name,
        amount: amount,
        currency: "USD",
        expected_day_of_month: 5,
        last_occurrence_date: 4.months.ago.to_date,
        next_expected_date: 1.month.from_now.to_date,
        occurrence_count: 1,
        status: "active"
      )
    end

    queries = nil
    assert_no_difference -> { @family.recurring_transactions.count } do
      queries = capture_sql_queries do
        @identifier.identify_recurring_patterns
      end
    end

    recurring_lookup_queries = queries.grep(
      /SELECT "recurring_transactions"\.\* FROM "recurring_transactions" WHERE .*"recurring_transactions"\."name" = .*LIMIT/
    )

    assert_empty recurring_lookup_queries
    recurring_transactions.each do |recurring|
      assert_equal 3, recurring.reload.occurrence_count
    end
  end

  test "updates manual recurring variance without per-recurring entry lookups" do
    account = @family.accounts.first
    names = Array.new(4) { |index| "Manual Performance Subscription #{index}" }

    recurring_transactions = names.each_with_index.map do |name, index|
      create_name_pattern_entries(
        account: account,
        name: name,
        amount: 50 + index,
        day: 6
      )

      @family.recurring_transactions.create!(
        account: account,
        name: name,
        amount: 50 + index,
        currency: "USD",
        expected_day_of_month: 6,
        last_occurrence_date: 4.months.ago.to_date,
        next_expected_date: 1.month.from_now.to_date,
        occurrence_count: 1,
        status: "active",
        manual: true
      )
    end

    queries = nil
    assert_no_difference -> { @family.recurring_transactions.count } do
      queries = capture_sql_queries do
        @identifier.identify_recurring_patterns
      end
    end

    entry_lookup_queries = queries.grep(
      /FROM "entries".*AND "entries"\."name" = .*ORDER BY "entries"\."date" DESC/
    )

    assert_empty entry_lookup_queries
    recurring_transactions.each do |recurring|
      assert_equal 3, recurring.reload.occurrence_count
    end
  end

  test "updates manual recurring variance across 1 to 31 month boundary" do
    travel_to Date.new(2026, 6, 7) do
      account = @family.accounts.first
      name = "Boundary Performance Subscription"
      recurring = @family.recurring_transactions.create!(
        account: account,
        name: name,
        amount: 72,
        currency: "USD",
        expected_day_of_month: 1,
        last_occurrence_date: 3.months.ago.to_date,
        next_expected_date: 1.month.from_now.to_date,
        occurrence_count: 0,
        status: "active",
        manual: true
      )

      transaction = Transaction.create!(
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: Date.new(2026, 5, 31),
        amount: 72,
        currency: "USD",
        name: name,
        entryable: transaction
      )

      assert_no_difference -> { @family.recurring_transactions.count } do
        @identifier.identify_recurring_patterns
      end

      recurring.reload
      assert_equal 1, recurring.occurrence_count
      assert_equal 72, recurring.expected_amount_min
      assert_equal Date.new(2026, 5, 31), recurring.last_occurrence_date
    end
  end

  test "updates manual recurring variance for expected end of month in February" do
    account = @family.accounts.first

    travel_to Date.new(2026, 3, 7) do
      name = "Non Leap Boundary Subscription"
      recurring = @family.recurring_transactions.create!(
        account: account,
        name: name,
        amount: 82,
        currency: "USD",
        expected_day_of_month: 31,
        last_occurrence_date: 3.months.ago.to_date,
        next_expected_date: 1.month.from_now.to_date,
        occurrence_count: 0,
        status: "active",
        manual: true
      )

      transaction = Transaction.create!(
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: Date.new(2026, 2, 28),
        amount: 82,
        currency: "USD",
        name: name,
        entryable: transaction
      )

      @identifier.identify_recurring_patterns

      recurring.reload
      assert_equal 1, recurring.occurrence_count
      assert_equal Date.new(2026, 2, 28), recurring.last_occurrence_date
    end

    travel_to Date.new(2024, 3, 7) do
      name = "Leap Boundary Subscription"
      recurring = @family.recurring_transactions.create!(
        account: account,
        name: name,
        amount: 92,
        currency: "USD",
        expected_day_of_month: 31,
        last_occurrence_date: 3.months.ago.to_date,
        next_expected_date: 1.month.from_now.to_date,
        occurrence_count: 0,
        status: "active",
        manual: true
      )

      transaction = Transaction.create!(
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: Date.new(2024, 2, 29),
        amount: 92,
        currency: "USD",
        name: name,
        entryable: transaction
      )

      @identifier.identify_recurring_patterns

      recurring.reload
      assert_equal 1, recurring.occurrence_count
      assert_equal Date.new(2024, 2, 29), recurring.last_occurrence_date
    end
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

  private
    def create_name_pattern_entries(account:, name:, amount:, day:)
      [ 0, 1, 2 ].each do |months_ago|
        transaction = Transaction.create!(
          category: categories(:food_and_drink)
        )
        account.entries.create!(
          date: months_ago.months.ago.beginning_of_month + (day - 1).days,
          amount: amount,
          currency: "USD",
          name: name,
          entryable: transaction
        )
      end
    end

    def capture_sql_queries
      queries = []
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        next if payload[:name].in?([ "SCHEMA", "TRANSACTION" ])

        queries << payload[:sql].squish
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        yield
      end

      queries
    end
end
