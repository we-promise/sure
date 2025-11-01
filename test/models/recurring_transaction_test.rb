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
end
