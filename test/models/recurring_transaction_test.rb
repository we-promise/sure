require "test_helper"

class RecurringTransactionTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @merchant = merchants(:netflix)
    # Clear any existing recurring transactions
    @family.recurring_transactions.destroy_all
  end

  test "identify_patterns_for creates recurring transactions for patterns with 3+ occurrences" do
    # Create a series of transactions with same merchant and amount on similar days
    # Use dates within the last 3 months: today, 1 month ago, 2 months ago
    account = @family.accounts.first
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 5.days,
        amount: 15.99,
        currency: "USD",
        name: "Netflix Subscription",
        entryable: transaction
      )
    end

    assert_difference "@family.recurring_transactions.count", 1 do
      RecurringTransaction.identify_patterns_for(@family)
    end

    recurring = @family.recurring_transactions.last
    assert_equal @merchant, recurring.merchant
    assert_equal 15.99, recurring.amount
    assert_equal "USD", recurring.currency
    assert_equal "active", recurring.status
    assert_equal 3, recurring.occurrence_count
  end

  test "identify_patterns_for does not create recurring transaction for less than 3 occurrences" do
    # Create only 2 transactions
    account = @family.accounts.first
    2.times do |i|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: (i + 1).months.ago.beginning_of_month + 5.days,
        amount: 15.99,
        currency: "USD",
        name: "Netflix Subscription",
        entryable: transaction
      )
    end

    assert_no_difference "@family.recurring_transactions.count" do
      RecurringTransaction.identify_patterns_for(@family)
    end
  end

  test "calculate_next_expected_date handles end of month correctly" do
    recurring = @family.recurring_transactions.create!(
      merchant: @merchant,
      amount: 29.99,
      currency: "USD",
      expected_day_of_month: 31,
      last_occurrence_date: Date.new(2025, 1, 31),
      next_expected_date: Date.new(2025, 2, 28),
      status: "active"
    )

    # February doesn't have 31 days, should return last day of February
    next_date = recurring.calculate_next_expected_date(Date.new(2025, 1, 31))
    assert_equal Date.new(2025, 2, 28), next_date
  end

  test "should_be_inactive? returns true when last occurrence is over 2 months ago" do
    recurring = @family.recurring_transactions.create!(
      merchant: merchants(:amazon),
      amount: 19.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: 3.months.ago.to_date,
      next_expected_date: 2.months.ago.to_date,
      status: "active"
    )

    assert recurring.should_be_inactive?
  end

  test "should_be_inactive? returns false when last occurrence is within 2 months" do
    recurring = @family.recurring_transactions.create!(
      merchant: merchants(:amazon),
      amount: 25.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: Date.current,
      status: "active"
    )

    assert_not recurring.should_be_inactive?
  end

  test "cleanup_stale_for marks inactive when no recent occurrences" do
    recurring = @family.recurring_transactions.create!(
      merchant: merchants(:amazon),
      amount: 35.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: 3.months.ago.to_date,
      next_expected_date: 2.months.ago.to_date,
      status: "active"
    )

    RecurringTransaction.cleanup_stale_for(@family)

    assert_equal "inactive", recurring.reload.status
  end

  test "record_occurrence! updates recurring transaction with new occurrence" do
    recurring = @family.recurring_transactions.create!(
      merchant: merchants(:amazon),
      amount: 45.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: Date.current,
      status: "active",
      occurrence_count: 3
    )

    new_date = Date.current
    recurring.record_occurrence!(new_date)

    assert_equal new_date, recurring.last_occurrence_date
    assert_equal 4, recurring.occurrence_count
    assert_equal "active", recurring.status
    assert recurring.next_expected_date > new_date
  end

  test "identify_patterns_for preserves sign for income transactions" do
    # Create recurring income transactions (negative amounts)
    account = @family.accounts.first
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:income)
      )
      account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 15.days,
        amount: -1000.00,
        currency: "USD",
        name: "Monthly Salary",
        entryable: transaction
      )
    end

    assert_difference "@family.recurring_transactions.count", 1 do
      RecurringTransaction.identify_patterns_for(@family)
    end

    recurring = @family.recurring_transactions.last
    assert_equal @merchant, recurring.merchant
    assert_equal(-1000.00, recurring.amount)
    assert recurring.amount.negative?, "Income should have negative amount"
    assert_equal "USD", recurring.currency
    assert_equal "active", recurring.status
  end

  test "identify_patterns_for creates name-based recurring transactions for transactions without merchants" do
    # Create transactions without merchants (e.g., from CSV imports or standard accounts)
    account = @family.accounts.first
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 10.days,
        amount: 25.00,
        currency: "USD",
        name: "Local Coffee Shop",
        entryable: transaction
      )
    end

    assert_difference "@family.recurring_transactions.count", 1 do
      RecurringTransaction.identify_patterns_for(@family)
    end

    recurring = @family.recurring_transactions.last
    assert_nil recurring.merchant
    assert_equal "Local Coffee Shop", recurring.name
    assert_equal 25.00, recurring.amount
    assert_equal "USD", recurring.currency
    assert_equal "active", recurring.status
    assert_equal 3, recurring.occurrence_count
  end

  test "identify_patterns_for creates separate patterns for same merchant but different names" do
    # Create two different recurring transactions from the same merchant
    account = @family.accounts.first

    # First pattern: Netflix Standard
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 5.days,
        amount: 15.99,
        currency: "USD",
        name: "Netflix Standard",
        entryable: transaction
      )
    end

    # Second pattern: Netflix Premium
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 10.days,
        amount: 19.99,
        currency: "USD",
        name: "Netflix Premium",
        entryable: transaction
      )
    end

    # Should create 2 patterns - one for each amount
    assert_difference "@family.recurring_transactions.count", 2 do
      RecurringTransaction.identify_patterns_for(@family)
    end
  end

  test "matching_transactions works with name-based recurring transactions" do
    # Skip when schema enforces NOT NULL merchant_id (branch-specific behavior)
    unless RecurringTransaction.columns_hash["merchant_id"].null
      skip "merchant_id is NOT NULL in this schema; name-based patterns disabled"
    end

    account = @family.accounts.first

    # Create transactions for pattern
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 15.days,
        amount: 50.00,
        currency: "USD",
        name: "Gym Membership",
        entryable: transaction
      )
    end

    RecurringTransaction.identify_patterns_for(@family)
    recurring = @family.recurring_transactions.last

    # Verify matching transactions finds the correct entries
    matches = recurring.matching_transactions
    assert_equal 3, matches.size
    assert matches.all? { |entry| entry.name == "Gym Membership" }
  end

  test "validation requires either merchant or name" do
    recurring = @family.recurring_transactions.build(
      amount: 25.00,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date
    )

    assert_not recurring.valid?
    assert_includes recurring.errors[:base], "Either merchant or name must be present"
  end

  test "both merchant-based and name-based patterns can coexist" do
    # Skip when schema enforces NOT NULL merchant_id (branch-specific behavior)
    unless RecurringTransaction.columns_hash["merchant_id"].null
      skip "merchant_id is NOT NULL in this schema; name-based patterns disabled"
    end
    account = @family.accounts.first

    # Create merchant-based pattern
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 5.days,
        amount: 15.99,
        currency: "USD",
        name: "Netflix Subscription",
        entryable: transaction
      )
    end

    # Create name-based pattern (no merchant)
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        category: categories(:one)
      )
      account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 1.days,
        amount: 1200.00,
        currency: "USD",
        name: "Monthly Rent",
        entryable: transaction
      )
    end

    assert_difference "@family.recurring_transactions.count", 2 do
      RecurringTransaction.identify_patterns_for(@family)
    end

    # Verify both types exist
    merchant_based = @family.recurring_transactions.where.not(merchant_id: nil).first
    name_based = @family.recurring_transactions.where(merchant_id: nil).first

    assert merchant_based.present?
    assert_equal @merchant, merchant_based.merchant

    assert name_based.present?
    assert_equal "Monthly Rent", name_based.name
  end

  # Manual recurring transaction tests
  test "create_from_transaction creates a manual recurring transaction" do
    account = @family.accounts.first
    transaction = Transaction.create!(
      merchant: @merchant,
      category: categories(:food_and_drink)
    )
    entry = account.entries.create!(
      date: 2.months.ago,
      amount: 50.00,
      currency: "USD",
      name: "Test Transaction",
      entryable: transaction
    )

    recurring = nil
    assert_difference "@family.recurring_transactions.count", 1 do
      recurring = RecurringTransaction.create_from_transaction(transaction)
    end

    assert recurring.present?
    assert recurring.manual?
    assert_equal @merchant, recurring.merchant
    assert_equal 50.00, recurring.amount
    assert_equal "USD", recurring.currency
    assert_equal 2.months.ago.day, recurring.expected_day_of_month
    assert_equal "active", recurring.status
    assert_equal 1, recurring.occurrence_count
    # Next expected date should be in the future (either this month or next month)
    assert recurring.next_expected_date >= Date.current
  end

  test "create_from_transaction automatically calculates amount variance from history" do
    account = @family.accounts.first

    # Create multiple historical transactions with varying amounts on the same day of month
    amounts = [ 90.00, 100.00, 110.00, 120.00 ]
    amounts.each_with_index do |amount, i|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: (amounts.size - i).months.ago.beginning_of_month + 14.days, # Day 15
        amount: amount,
        currency: "USD",
        name: "Test Transaction",
        entryable: transaction
      )
    end

    # Mark the most recent one as recurring
    most_recent_entry = account.entries.order(date: :desc).first
    recurring = RecurringTransaction.create_from_transaction(most_recent_entry.transaction)

    assert recurring.manual?
    assert_equal 90.00, recurring.expected_amount_min
    assert_equal 120.00, recurring.expected_amount_max
    assert_equal 105.00, recurring.expected_amount_avg # (90 + 100 + 110 + 120) / 4
    assert_equal 4, recurring.occurrence_count
    # Next expected date should be in the future
    assert recurring.next_expected_date >= Date.current
  end

  test "create_from_transaction with single transaction sets fixed amount" do
    account = @family.accounts.first
    transaction = Transaction.create!(
      merchant: @merchant,
      category: categories(:food_and_drink)
    )
    entry = account.entries.create!(
      date: 1.month.ago,
      amount: 50.00,
      currency: "USD",
      name: "Test Transaction",
      entryable: transaction
    )

    recurring = RecurringTransaction.create_from_transaction(transaction)

    assert recurring.manual?
    assert_equal 50.00, recurring.expected_amount_min
    assert_equal 50.00, recurring.expected_amount_max
    assert_equal 50.00, recurring.expected_amount_avg
    assert_equal 1, recurring.occurrence_count
    # Next expected date should be in the future
    assert recurring.next_expected_date >= Date.current
  end

  test "matching_transactions with amount variance matches within range" do
    account = @family.accounts.first

    # Create manual recurring with variance for day 15 of the month
    recurring = @family.recurring_transactions.create!(
      merchant: @merchant,
      amount: 100.00,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: 1.month.ago,
      next_expected_date: Date.current.next_month.beginning_of_month + 14.days,
      status: "active",
      manual: true,
      expected_amount_min: 80.00,
      expected_amount_max: 120.00,
      expected_amount_avg: 100.00
    )

    # Create transactions with varying amounts on day 14 (within ±2 days of day 15)
    transaction_within_range = Transaction.create!(merchant: @merchant, category: categories(:food_and_drink))
    entry_within = account.entries.create!(
      date: Date.current.next_month.beginning_of_month + 13.days, # Day 14
      amount: 90.00,
      currency: "USD",
      name: "Test Transaction",
      entryable: transaction_within_range
    )

    transaction_outside_range = Transaction.create!(merchant: @merchant, category: categories(:food_and_drink))
    entry_outside = account.entries.create!(
      date: Date.current.next_month.beginning_of_month + 14.days, # Day 15
      amount: 150.00,
      currency: "USD",
      name: "Test Transaction",
      entryable: transaction_outside_range
    )

    matches = recurring.matching_transactions
    assert_includes matches, entry_within
    assert_not_includes matches, entry_outside
  end

  test "should_be_inactive? has longer threshold for manual recurring" do
    # Manual recurring - 6 months threshold
    manual_recurring = @family.recurring_transactions.create!(
      merchant: @merchant,
      amount: 50.00,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: 5.months.ago,
      next_expected_date: 15.days.from_now,
      status: "active",
      manual: true
    )

    # Auto recurring - 2 months threshold with different amount to avoid unique constraint
    auto_recurring = @family.recurring_transactions.create!(
      merchant: @merchant,
      amount: 60.00,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: 3.months.ago,
      next_expected_date: 15.days.from_now,
      status: "active",
      manual: false
    )

    assert_not manual_recurring.should_be_inactive?
    assert auto_recurring.should_be_inactive?
  end

  test "update_amount_variance updates min/max/avg correctly" do
    recurring = @family.recurring_transactions.create!(
      merchant: @merchant,
      amount: 100.00,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now,
      status: "active",
      manual: true,
      occurrence_count: 1
    )

    # Record first occurrence with amount variance
    recurring.record_occurrence!(Date.current, 100.00)
    assert_equal 100.00, recurring.expected_amount_min.to_f
    assert_equal 100.00, recurring.expected_amount_max.to_f
    assert_equal 100.00, recurring.expected_amount_avg.to_f

    # Record second occurrence with different amount
    recurring.record_occurrence!(1.month.from_now, 120.00)
    assert_equal 100.00, recurring.expected_amount_min.to_f
    assert_equal 120.00, recurring.expected_amount_max.to_f
    assert_in_delta 110.00, recurring.expected_amount_avg.to_f, 0.01

    # Record third occurrence with lower amount
    recurring.record_occurrence!(2.months.from_now, 90.00)
    assert_equal 90.00, recurring.expected_amount_min.to_f
    assert_equal 120.00, recurring.expected_amount_max.to_f
    assert_in_delta 103.33, recurring.expected_amount_avg.to_f, 0.01
  end

  test "identify_patterns_for updates variance for manual recurring transactions" do
    account = @family.accounts.first

    # Create a manual recurring transaction with initial variance
    manual_recurring = @family.recurring_transactions.create!(
      merchant: @merchant,
      amount: 50.00,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: 3.months.ago,
      next_expected_date: 1.month.from_now,
      status: "active",
      manual: true,
      occurrence_count: 1,
      expected_amount_min: 50.00,
      expected_amount_max: 50.00,
      expected_amount_avg: 50.00
    )

    # Create new transactions with varying amounts that would match the pattern
    amounts = [ 45.00, 55.00, 60.00 ]
    amounts.each_with_index do |amount, i|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:food_and_drink)
      )
      account.entries.create!(
        date: (amounts.size - i).months.ago.beginning_of_month + 14.days,
        amount: amount,
        currency: "USD",
        name: "Test Transaction",
        entryable: transaction
      )
    end

    # Run pattern identification
    assert_no_difference "@family.recurring_transactions.count" do
      RecurringTransaction.identify_patterns_for(@family)
    end

    # Manual recurring should be updated with new variance
    manual_recurring.reload
    assert manual_recurring.manual?
    assert_equal 45.00, manual_recurring.expected_amount_min
    assert_equal 60.00, manual_recurring.expected_amount_max
    assert_in_delta 53.33, manual_recurring.expected_amount_avg.to_f, 0.01 # (45 + 55 + 60) / 3
    assert manual_recurring.occurrence_count > 1
  end

  test "cleaner does not delete manual recurring transactions" do
    # Create inactive manual recurring
    manual_recurring = @family.recurring_transactions.create!(
      merchant: @merchant,
      amount: 50.00,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: 1.year.ago,
      next_expected_date: 1.year.ago + 1.month,
      status: "inactive",
      manual: true,
      occurrence_count: 1
    )
    # Set updated_at to be old enough for cleanup
    manual_recurring.update_column(:updated_at, 1.year.ago)

    # Create inactive auto recurring with different merchant
    auto_recurring = @family.recurring_transactions.create!(
      merchant: merchants(:amazon),
      amount: 30.00,
      currency: "USD",
      expected_day_of_month: 10,
      last_occurrence_date: 1.year.ago,
      next_expected_date: 1.year.ago + 1.month,
      status: "inactive",
      manual: false,
      occurrence_count: 1
    )
    # Set updated_at to be old enough for cleanup
    auto_recurring.update_column(:updated_at, 1.year.ago)

    cleaner = RecurringTransaction::Cleaner.new(@family)
    cleaner.remove_old_inactive_transactions

    assert RecurringTransaction.exists?(manual_recurring.id)
    assert_not RecurringTransaction.exists?(auto_recurring.id)
  end
end
