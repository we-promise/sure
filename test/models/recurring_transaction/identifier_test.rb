require "test_helper"

class RecurringTransaction::IdentifierTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @identifier = RecurringTransaction::Identifier.new(@family)
    @family.recurring_transactions.destroy_all
  end

  test "candidate_patterns offers undeclared recurring shapes and skips claimed, junk, and wrong-sign ones" do
    account = @family.accounts.first

    # An undeclared recurring charge: two occurrences on the same day.
    2.times do |i|
      account.entries.create!(
        date: (i + 1).months.ago.to_date,
        amount: 45.00,
        currency: "USD",
        name: "City Water",
        entryable: Transaction.create!(category: categories(:food_and_drink))
      )
    end

    # A recurring deposit: inflow, so an income candidate only.
    2.times do |i|
      account.entries.create!(
        date: (i + 1).months.ago.to_date,
        amount: -1840.00,
        currency: "USD",
        name: "ACME PAYROLL",
        entryable: Transaction.create!(category: categories(:food_and_drink))
      )
    end

    # A penny sweep recurs but is never worth offering.
    2.times do |i|
      account.entries.create!(
        date: (i + 1).months.ago.to_date,
        amount: 0.01,
        currency: "USD",
        name: "To Car Vault",
        entryable: Transaction.create!(category: categories(:food_and_drink))
      )
    end

    # An already-declared charge must not be re-offered.
    2.times do |i|
      account.entries.create!(
        date: (i + 1).months.ago.to_date,
        amount: 90.00,
        currency: "USD",
        name: "Internet Co",
        entryable: Transaction.create!(category: categories(:food_and_drink))
      )
    end
    @family.recurring_transactions.create!(
      name: "Internet Co",
      account: account,
      amount: 90.00,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 1.month.from_now.to_date,
      status: "active",
      manual: true
    )

    bill_names = @identifier.candidate_patterns(sign: :outflow).map { |pattern| pattern[:name] }
    income_names = @identifier.candidate_patterns(sign: :inflow).map { |pattern| pattern[:name] }

    assert_includes bill_names, "City Water"
    assert_not_includes bill_names, "ACME PAYROLL", "inflows are not bill candidates"
    assert_not_includes bill_names, "To Car Vault", "sub-dollar patterns are junk"
    assert_not_includes bill_names, "Internet Co", "declared series are not re-offered"
    assert_equal [ "ACME PAYROLL" ], income_names
  end

  test "income_source_candidates surfaces a variable weekly paycheck the pattern gate cannot see" do
    account = @family.accounts.first

    # Weekly pay, hours-driven amounts: no amount cluster, no stable day of month.
    [ [ 63, 1199.0 ], [ 56, 1393.75 ], [ 49, 1996.81 ], [ 42, 434.95 ], [ 35, 1254.77 ] ].each do |days_ago, amount|
      account.entries.create!(
        date: days_ago.days.ago.to_date,
        amount: -amount,
        currency: "USD",
        name: "ACME PAYROLL",
        entryable: Transaction.create!(category: categories(:food_and_drink))
      )
    end

    # Interest pennies recur but are never a payday.
    2.times do |i|
      account.entries.create!(
        date: (i + 1).months.ago.end_of_month,
        amount: -0.31,
        currency: "USD",
        name: "Interest earned",
        entryable: Transaction.create!(category: categories(:food_and_drink))
      )
    end

    candidates = @identifier.income_source_candidates

    assert_equal [ "ACME PAYROLL" ], candidates.map { |candidate| candidate[:name] }
    assert_equal 5, candidates.first[:occurrence_count]
    assert @identifier.candidate_patterns(sign: :inflow).none? { |pattern| pattern[:occurrence_count] == 5 },
           "the amount-cluster path cannot see the whole variable-pay source; the source path must"
  end

  test "income_source_candidates skips sources already declared as income regardless of amount" do
    account = @family.accounts.first

    [ [ 40, 1500.0 ], [ 26, 900.0 ], [ 12, 2100.0 ] ].each do |days_ago, amount|
      account.entries.create!(
        date: days_ago.days.ago.to_date,
        amount: -amount,
        currency: "USD",
        name: "ACME PAYROLL",
        entryable: Transaction.create!(category: categories(:food_and_drink))
      )
    end

    @family.recurring_transactions.create!(
      name: "ACME PAYROLL",
      account: account,
      amount: -1800.00,
      currency: "USD",
      bill_type: "income",
      expected_day_of_month: 15,
      last_occurrence_date: 12.days.ago.to_date,
      next_expected_date: Date.current + 2,
      status: "active",
      manual: true
    )

    assert_empty @identifier.income_source_candidates
  end

  test "candidate_patterns needs only two consistent occurrences while identify still needs three" do
    account = @family.accounts.first

    2.times do |i|
      account.entries.create!(
        date: (i + 1).months.ago.to_date,
        amount: 45.00,
        currency: "USD",
        name: "City Water",
        entryable: Transaction.create!(category: categories(:food_and_drink))
      )
    end

    assert_equal 1, @identifier.candidate_patterns(sign: :outflow).size
    assert_equal 0, @identifier.identify_recurring_patterns
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

    # Days 30, 31, 1 and 2: all within the 2-day tolerance of the expected
    # day ON THE CIRCLE, which is what makes a month-boundary biller one
    # pattern. (A wider wobble is deliberately no longer a pattern:
    # consistency is per-occurrence, not on average.)
    dates = [
      Date.new(2026, 5, 30),
      Date.new(2026, 5, 31),
      Date.new(2026, 7, 1),
      Date.new(2026, 8, 2)
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

    patterns_count = travel_to(Date.new(2026, 8, 13)) { @identifier.identify_recurring_patterns }

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

  test "claims the nearest existing series per amount cluster without per-pattern lookups" do
    account = @family.accounts.first
    name = "Tiered Performance Subscription"

    # Two tiers under one identity: the second carries a dedup_scope
    # discriminator, exactly as the detector stamps it.
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
        dedup_scope: amount == 40 ? "" : amount.to_s,
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

  # A weekly cadence lands on a weekday, not near one day of the month, so the
  # variance refresh must keep every weekly payment instead of only the ones
  # that happen to sit within two days of expected_day_of_month.
  test "updates manual weekly variance from every payment on the series' weekday" do
    travel_to Date.new(2026, 6, 20) do
      account = @family.accounts.first
      name = "Weekly Lawn Service"
      fridays = [ Date.new(2026, 5, 29), Date.new(2026, 6, 5), Date.new(2026, 6, 12), Date.new(2026, 6, 19) ]

      recurring = @family.recurring_transactions.create!(
        account: account,
        name: name,
        amount: 40,
        currency: "USD",
        expected_day_of_month: fridays.first.day,
        anchor_date: fridays.first,
        last_occurrence_date: fridays.first,
        next_expected_date: fridays.second,
        occurrence_count: 0,
        status: "active",
        manual: true
      )
      RecurringTransaction::FrequencyPreset.apply(recurring, preset: "weekly", weekday: 5)
      recurring.save!

      fridays.each do |date|
        account.entries.create!(
          date: date,
          amount: 40,
          currency: "USD",
          name: name,
          entryable: Transaction.create!(category: categories(:food_and_drink))
        )
      end

      assert_no_difference -> { @family.recurring_transactions.count } do
        @identifier.identify_recurring_patterns
      end

      recurring.reload
      assert_equal 4, recurring.occurrence_count,
        "every Friday payment counts, including the ones across the month boundary"
      assert_equal fridays.last, recurring.last_occurrence_date
    end
  end

  # The next-due bookkeeping and the regenerated occurrences must agree: when
  # detection observes a day shift, next_expected_date has to follow the new
  # day immediately, not one detection run later.
  test "a detected day shift moves next_expected_date onto the new day" do
    travel_to Date.new(2026, 6, 20) do
      account = @family.accounts.first
      name = "Shifted Gym Membership"
      recurring = @family.recurring_transactions.create!(
        account: account,
        name: name,
        amount: 55,
        currency: "USD",
        expected_day_of_month: 5,
        last_occurrence_date: Date.new(2026, 5, 5),
        next_expected_date: Date.new(2026, 7, 5),
        occurrence_count: 3,
        status: "active",
        manual: false
      )

      [ Date.new(2026, 4, 12), Date.new(2026, 5, 12), Date.new(2026, 6, 12) ].each do |date|
        account.entries.create!(
          date: date,
          amount: 55,
          currency: "USD",
          name: name,
          entryable: Transaction.create!(category: categories(:food_and_drink))
        )
      end

      @identifier.identify_recurring_patterns

      recurring.reload
      assert_equal 12, recurring.expected_day_of_month
      assert_equal 12, recurring.next_expected_date.day,
        "the persisted next due date must use the newly detected day"
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

  test "scattered days are not a recurring pattern, whatever their average" do
    # Charges on the 3rd, 10th and 16th averaged out under the old std-dev
    # gate; per-occurrence consistency rejects them.
    account = @family.accounts.first
    [ [ 0, 3 ], [ 1, 10 ], [ 2, 16 ] ].each do |months_ago, day|
      transaction = Transaction.create!(category: categories(:food_and_drink))
      account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + (day - 1).days,
        amount: 30, currency: "USD", name: "SCATTERED CHARGES",
        entryable: transaction
      )
    end

    assert_no_difference -> { @family.recurring_transactions.count } do
      @identifier.identify_recurring_patterns
    end
  end

  test "short-month clamping still reads as the same day" do
    account = @family.accounts.first
    # A day-30 bill: Feb lands on the 28th, two away on the circle -- in.
    [ Date.new(2026, 1, 30), Date.new(2026, 2, 28), Date.new(2026, 3, 30) ].each do |date|
      transaction = Transaction.create!(category: categories(:food_and_drink))
      account.entries.create!(
        date: date, amount: 55, currency: "USD", name: "MONTH END BILL",
        entryable: transaction
      )
    end

    travel_to Date.new(2026, 4, 10) do
      assert_difference -> { @family.recurring_transactions.count }, 1 do
        @identifier.identify_recurring_patterns
      end
    end
  end

  test "a price change within tolerance stays one series" do
    account = @family.accounts.first
    recurring = @family.recurring_transactions.create!(
      account: account,
      name: "Fiber Internet",
      amount: 79.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: 4.months.ago.to_date,
      next_expected_date: 1.month.from_now.to_date,
      occurrence_count: 3,
      status: "active"
    )

    # Price crept to 81.99 (2.5%): same obligation, must not fork a new row.
    create_name_pattern_entries(account: account, name: "Fiber Internet", amount: 81.99, day: 5)

    assert_no_difference -> { @family.recurring_transactions.count } do
      @identifier.identify_recurring_patterns
    end

    recurring.reload
    assert_equal 79.99, recurring.amount, "amount updates are the price-change detector's call, not detection's"
    assert_equal 81.99, recurring.expected_amount_min
    assert_equal 81.99, recurring.expected_amount_max
  end

  test "new detections land as suggested and stamp dedup_scope when the identity is taken" do
    account = @family.accounts.first
    @family.recurring_transactions.create!(
      account: account,
      name: "STREAMCO",
      amount: 5.99,
      currency: "USD",
      expected_day_of_month: 8,
      last_occurrence_date: 4.months.ago.to_date,
      next_expected_date: 1.month.from_now.to_date,
      occurrence_count: 3,
      status: "active"
    )

    # A second, genuinely different tier: far outside tolerance of 5.99.
    create_name_pattern_entries(account: account, name: "STREAMCO", amount: 24.99, day: 21)

    assert_difference -> { @family.recurring_transactions.count }, 1 do
      @identifier.identify_recurring_patterns
    end

    created = @family.recurring_transactions.order(:created_at).last
    assert_equal "suggested", created.status
    assert_equal "24.99", created.dedup_scope
    assert_not created.manual?
  end

  test "detection never recreates a manual bill or a dismissed one" do
    account = @family.accounts.first

    manual = @family.recurring_transactions.create!(
      account: account,
      name: "Declared Rent",
      amount: 2150,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: 2.months.ago.to_date,
      next_expected_date: 1.month.from_now.to_date,
      occurrence_count: 1,
      status: "active",
      manual: true
    )
    create_name_pattern_entries(account: account, name: "Declared Rent", amount: 2150, day: 5)

    dismissed = @family.recurring_transactions.create!(
      account: account,
      name: "Not A Bill",
      amount: 12.50,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: 2.months.ago.to_date,
      next_expected_date: 1.month.from_now.to_date,
      occurrence_count: 3,
      status: "ended"
    )
    create_name_pattern_entries(account: account, name: "Not A Bill", amount: 12.50, day: 5)

    assert_no_difference -> { @family.recurring_transactions.count } do
      @identifier.identify_recurring_patterns
    end

    assert_equal "ended", dismissed.reload.status
    assert manual.reload.manual?
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

    # `manual` is set at creation and no edit flips it, so a detected bill whose
    # due day the user corrected by hand was reverted by the next sync, which
    # also regenerated its future occurrences on the rejected day.
    test "detection leaves a hand-pinned schedule alone" do
      series = detected_monthly_series

      RecurringTransaction::FrequencyPreset.apply(series, preset: "monthly", day_of_month: 20)
      series.pin_schedule
      series.save!

      RecurringTransaction::Identifier.new(Family.find(@family.id)).identify_recurring_patterns
      series = RecurringTransaction.find(series.id)

      assert_equal 20, series.recurrence_rules.first.day_of_month,
        "the day the user set survives the next sync"
      assert_equal 20, series.expected_day_of_month,
        "and the series reports the day the user set, not the observed one"
    end

    # Negative control: without the pin, detection still corrects the due day to
    # the day the charges actually land on. Without this the guard above could
    # pass by simply switching the feature off.
    test "detection still tracks the observed day when nothing is pinned" do
      series = detected_monthly_series
      observed_day = series.expected_day_of_month

      RecurringTransaction::FrequencyPreset.apply(series, preset: "monthly", day_of_month: 20)
      series.save!
      assert_equal 20, RecurringTransaction.find(series.id).expected_day_of_month

      RecurringTransaction::Identifier.new(Family.find(@family.id)).identify_recurring_patterns
      series = RecurringTransaction.find(series.id)

      assert_not series.schedule_pinned?
      assert_equal observed_day, series.expected_day_of_month,
        "an unpinned series is still corrected to the day its charges land on"
    end

  private
    # Three same-day charges inside the detection window: the smallest thing
    # the Identifier will turn into a monthly series.
    def detected_monthly_series
      account = @family.accounts.first
      anchor = Date.current.beginning_of_month + 8

      3.times do |i|
        account.entries.create!(
          date: anchor - i.months,
          amount: 45.00, currency: "USD", name: "City Water",
          entryable: Transaction.create!(category: categories(:food_and_drink))
        )
      end

      RecurringTransaction::Identifier.new(@family).identify_recurring_patterns
      @family.recurring_transactions.find_by(name: "City Water").tap do |series|
        raise "fixture did not produce a detected series" if series.nil?
        raise "fixture produced a manual series" if series.manual?
      end
    end
end
