require "test_helper"

class RecurringTransactionTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @merchant = merchants(:netflix)
    @account = accounts(:depository)
    # Clear any existing recurring transactions
    @family.recurring_transactions.destroy_all
  end

  test "status is required" do
    recurring = @family.recurring_transactions.build(
      account: @account,
      merchant: @merchant,
      amount: 29.99,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      status: nil
    )

    assert_not recurring.valid?
    assert_includes recurring.errors[:status], "can't be blank"
  end

  test "occurrence count cannot be negative" do
    recurring = @family.recurring_transactions.build(
      account: @account,
      merchant: @merchant,
      amount: 29.99,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      status: "active",
      occurrence_count: -1
    )

    assert_not recurring.valid?
    assert_includes recurring.errors[:occurrence_count], "must be greater than or equal to 0"
  end

  test "identify_patterns_for creates recurring transactions for patterns with 3+ occurrences" do
    # Create a series of transactions with same merchant and amount on similar days
    # Use dates within the last 3 months: today, 1 month ago, 2 months ago
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:food_and_drink)
      )
      @account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 5.days,
        amount: 15.99,
        currency: "USD",
        name: "Netflix Subscription",
        entryable: transaction
      )
    end

    assert_difference "@family.recurring_transactions.count", 1 do
      RecurringTransaction.identify_patterns_for!(@family)
    end

    recurring = @family.recurring_transactions.last
    assert_equal @merchant, recurring.merchant
    assert_equal @account, recurring.account
    assert_equal 15.99, recurring.amount
    assert_equal "USD", recurring.currency
    assert_equal "active", recurring.status
    assert_equal 3, recurring.occurrence_count
  end

  test "identify_patterns_for does not create recurring transaction for less than 3 occurrences" do
    # Create only 2 transactions
    2.times do |i|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:food_and_drink)
      )
      @account.entries.create!(
        date: (i + 1).months.ago.beginning_of_month + 5.days,
        amount: 15.99,
        currency: "USD",
        name: "Netflix Subscription",
        entryable: transaction
      )
    end

    assert_no_difference "@family.recurring_transactions.count" do
      RecurringTransaction.identify_patterns_for!(@family)
    end
  end

  test "calculate_next_expected_date handles end of month correctly" do
    recurring = @family.recurring_transactions.create!(
      account: @account,
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
      account: @account,
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
      account: @account,
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
      account: @account,
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
      account: @account,
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
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:income)
      )
      @account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 15.days,
        amount: -1000.00,
        currency: "USD",
        name: "Monthly Salary",
        entryable: transaction
      )
    end

    assert_difference "@family.recurring_transactions.count", 1 do
      RecurringTransaction.identify_patterns_for!(@family)
    end

    recurring = @family.recurring_transactions.last
    assert_equal @merchant, recurring.merchant
    assert_equal @account, recurring.account
    assert_equal(-1000.00, recurring.amount)
    assert recurring.amount.negative?, "Income should have negative amount"
    assert_equal "USD", recurring.currency
    assert_equal "active", recurring.status
  end

  test "identify_patterns_for creates name-based recurring transactions for transactions without merchants" do
    # Create transactions without merchants (e.g., from CSV imports or standard accounts)
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        category: categories(:food_and_drink)
      )
      @account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 10.days,
        amount: 25.00,
        currency: "USD",
        name: "Local Coffee Shop",
        entryable: transaction
      )
    end

    assert_difference "@family.recurring_transactions.count", 1 do
      RecurringTransaction.identify_patterns_for!(@family)
    end

    recurring = @family.recurring_transactions.last
    assert_nil recurring.merchant
    assert_equal @account, recurring.account
    assert_equal "Local Coffee Shop", recurring.name
    assert_equal 25.00, recurring.amount
    assert_equal "USD", recurring.currency
    assert_equal "active", recurring.status
    assert_equal 3, recurring.occurrence_count
  end

  test "identify_patterns_for creates separate patterns for same merchant but different names" do
    # Create two different recurring transactions from the same merchant

    # First pattern: Netflix Standard
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:food_and_drink)
      )
      @account.entries.create!(
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
      @account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 10.days,
        amount: 19.99,
        currency: "USD",
        name: "Netflix Premium",
        entryable: transaction
      )
    end

    # Should create 2 patterns - one for each amount
    assert_difference "@family.recurring_transactions.count", 2 do
      RecurringTransaction.identify_patterns_for!(@family)
    end
  end

  test "matching_transactions works with name-based recurring transactions" do
    # Skip when schema enforces NOT NULL merchant_id (branch-specific behavior)
    unless RecurringTransaction.columns_hash["merchant_id"].null
      skip "merchant_id is NOT NULL in this schema; name-based patterns disabled"
    end

    # Create transactions for pattern
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        category: categories(:food_and_drink)
      )
      @account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 15.days,
        amount: 50.00,
        currency: "USD",
        name: "Gym Membership",
        entryable: transaction
      )
    end

    RecurringTransaction.identify_patterns_for!(@family)
    recurring = @family.recurring_transactions.last

    # Verify matching transactions finds the correct entries
    matches = recurring.matching_transactions
    assert_equal 3, matches.size
    assert matches.all? { |entry| entry.name == "Gym Membership" }
  end

  test "validation requires either merchant or name" do
    recurring = @family.recurring_transactions.build(
      account: @account,
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

    # Create merchant-based pattern
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:food_and_drink)
      )
      @account.entries.create!(
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
      @account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 1.days,
        amount: 1200.00,
        currency: "USD",
        name: "Monthly Rent",
        entryable: transaction
      )
    end

    assert_difference "@family.recurring_transactions.count", 2 do
      RecurringTransaction.identify_patterns_for!(@family)
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
    transaction = Transaction.create!(
      merchant: @merchant,
      category: categories(:food_and_drink)
    )
    entry = @account.entries.create!(
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
    assert_equal @account, recurring.account
    assert_equal 50.00, recurring.amount
    assert_equal "USD", recurring.currency
    assert_equal 2.months.ago.day, recurring.expected_day_of_month
    assert_equal "active", recurring.status
    assert_equal 1, recurring.occurrence_count
    # Next expected date should be in the future (either this month or next month)
    assert recurring.next_expected_date >= Date.current
  end

  test "create_from_transaction automatically calculates amount variance from history" do
    # Create multiple historical transactions with varying amounts on the same day of month
    amounts = [ 90.00, 100.00, 110.00, 120.00 ]
    amounts.each_with_index do |amount, i|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:food_and_drink)
      )
      @account.entries.create!(
        date: (amounts.size - i).months.ago.beginning_of_month + 14.days, # Day 15
        amount: amount,
        currency: "USD",
        name: "Test Transaction",
        entryable: transaction
      )
    end

    # Mark the most recent one as recurring (find the 120.00 entry we created last)
    most_recent_entry = @account.entries.where(amount: 120.00, currency: "USD").order(date: :desc).first
    recurring = RecurringTransaction.create_from_transaction(most_recent_entry.transaction)

    assert recurring.manual?
    assert_equal @account, recurring.account
    assert_equal 90.00, recurring.expected_amount_min
    assert_equal 120.00, recurring.expected_amount_max
    assert_equal 105.00, recurring.expected_amount_avg # (90 + 100 + 110 + 120) / 4
    assert_equal 4, recurring.occurrence_count
    # Next expected date should be in the future
    assert recurring.next_expected_date >= Date.current
  end

  test "create_from_transaction with single transaction sets fixed amount" do
    transaction = Transaction.create!(
      merchant: @merchant,
      category: categories(:food_and_drink)
    )
    entry = @account.entries.create!(
      date: 1.month.ago,
      amount: 50.00,
      currency: "USD",
      name: "Test Transaction",
      entryable: transaction
    )

    recurring = RecurringTransaction.create_from_transaction(transaction)

    assert recurring.manual?
    assert_equal @account, recurring.account
    assert_equal 50.00, recurring.expected_amount_min
    assert_equal 50.00, recurring.expected_amount_max
    assert_equal 50.00, recurring.expected_amount_avg
    assert_equal 1, recurring.occurrence_count
    # Next expected date should be in the future
    assert recurring.next_expected_date >= Date.current
  end

  test "matching_transactions with amount variance matches within range" do
    # Create manual recurring with variance for day 15 of the month
    recurring = @family.recurring_transactions.create!(
      account: @account,
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

    # Create transactions with varying amounts on day 14 (within +/-2 days of day 15)
    transaction_within_range = Transaction.create!(merchant: @merchant, category: categories(:food_and_drink))
    entry_within = @account.entries.create!(
      date: Date.current.next_month.beginning_of_month + 13.days, # Day 14
      amount: 90.00,
      currency: "USD",
      name: "Test Transaction",
      entryable: transaction_within_range
    )

    transaction_outside_range = Transaction.create!(merchant: @merchant, category: categories(:food_and_drink))
    entry_outside = @account.entries.create!(
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
      account: @account,
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
      account: @account,
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
      account: @account,
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
    # Create a manual recurring transaction with initial variance
    manual_recurring = @family.recurring_transactions.create!(
      account: @account,
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
      @account.entries.create!(
        date: (amounts.size - i).months.ago.beginning_of_month + 14.days,
        amount: amount,
        currency: "USD",
        name: "Test Transaction",
        entryable: transaction
      )
    end

    # Run pattern identification
    assert_no_difference "@family.recurring_transactions.count" do
      RecurringTransaction.identify_patterns_for!(@family)
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
      account: @account,
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
      account: @account,
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

  # Account access scoping tests
  test "accessible_by scope returns only recurring transactions from accessible accounts" do
    admin = users(:family_admin)
    member = users(:family_member)

    # depository is shared with family_member (full_control)
    # investment is NOT shared with family_member
    shared_account = accounts(:depository)
    unshared_account = accounts(:investment)

    shared_recurring = @family.recurring_transactions.create!(
      account: shared_account,
      merchant: @merchant,
      amount: 15.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 5.days.from_now.to_date,
      status: "active"
    )

    unshared_recurring = @family.recurring_transactions.create!(
      account: unshared_account,
      merchant: merchants(:amazon),
      amount: 9.99,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 5.days.from_now.to_date,
      status: "active"
    )

    # Admin (owner of all accounts) sees both
    admin_results = @family.recurring_transactions.accessible_by(admin)
    assert_includes admin_results, shared_recurring
    assert_includes admin_results, unshared_recurring

    # Family member only sees the one from the shared account
    member_results = @family.recurring_transactions.accessible_by(member)
    assert_includes member_results, shared_recurring
    assert_not_includes member_results, unshared_recurring
  end

  test "identifier creates per-account patterns for same merchant on different accounts" do
    account_a = accounts(:depository)
    account_b = accounts(:credit_card)

    # Create pattern on account A
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:food_and_drink)
      )
      account_a.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 5.days,
        amount: 15.99,
        currency: "USD",
        name: "Netflix Subscription",
        entryable: transaction
      )
    end

    # Create same pattern on account B
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(
        merchant: @merchant,
        category: categories(:food_and_drink)
      )
      account_b.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 5.days,
        amount: 15.99,
        currency: "USD",
        name: "Netflix Subscription",
        entryable: transaction
      )
    end

    assert_difference "@family.recurring_transactions.count", 2 do
      RecurringTransaction.identify_patterns_for!(@family)
    end

    recurring_a = @family.recurring_transactions.find_by(account: account_a, merchant: @merchant, amount: 15.99)
    recurring_b = @family.recurring_transactions.find_by(account: account_b, merchant: @merchant, amount: 15.99)

    assert recurring_a.present?
    assert recurring_b.present?
    assert_not_equal recurring_a, recurring_b
  end

  # ----- Recurring transfers (issue #895 / discussion #1224) -----

  test "transfer? is false when destination_account is absent" do
    rt = @family.recurring_transactions.create!(
      account: @account,
      name: "Spotify",
      amount: 9.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: Date.current,
      next_expected_date: 5.days.from_now.to_date,
      manual: true
    )
    assert_not rt.transfer?
  end

  test "transfer? is true when destination_account is present" do
    destination = accounts(:credit_card)
    rt = @family.recurring_transactions.create!(
      account: @account,
      destination_account: destination,
      name: "Transfer to #{destination.name}",
      amount: 500,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      manual: true
    )
    assert rt.transfer?
  end

  test "validation rejects same source and destination accounts" do
    rt = @family.recurring_transactions.build(
      account: @account,
      destination_account: @account,
      name: "Self-transfer",
      amount: 100,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      manual: true
    )
    assert_not rt.valid?
    assert_includes rt.errors[:destination_account], "cannot be the same as the source account"
  end

  test "validation rejects dangling source account_id (account does not exist)" do
    rt = @family.recurring_transactions.build(
      account_id: SecureRandom.uuid, # references nothing
      destination_account: accounts(:credit_card),
      name: "Phantom source",
      amount: 100,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      manual: true
    )
    assert_not rt.valid?
    assert_includes rt.errors[:account], "must exist"
  end

  test "validation rejects dangling destination_account_id (account does not exist)" do
    rt = @family.recurring_transactions.build(
      account: @account,
      destination_account_id: SecureRandom.uuid, # references nothing
      name: "Phantom transfer",
      amount: 100,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      manual: true
    )
    assert_not rt.valid?
    assert_includes rt.errors[:destination_account], "must exist"
  end

  test "validation rejects destination on different family" do
    other_family = Family.create!(name: "Other", locale: "en", date_format: "%Y-%m-%d", currency: "USD")
    other_account = other_family.accounts.create!(name: "Other depository", balance: 0, currency: "USD", accountable: Depository.new)

    rt = @family.recurring_transactions.build(
      account: @account,
      destination_account: other_account,
      name: "Foreign transfer",
      amount: 100,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      manual: true
    )
    assert_not rt.valid?
    assert_includes rt.errors[:destination_account], "must belong to the same family as the source account"
  end

  test "create_from_transfer builds a recurring transfer with both endpoints" do
    source = @account
    destination = accounts(:credit_card)

    outflow_entry = source.entries.create!(
      date: 5.days.ago.to_date, amount: 250, currency: "USD",
      name: "Manual transfer",
      entryable: Transaction.new(kind: "standard")
    )
    inflow_entry = destination.entries.create!(
      date: 5.days.ago.to_date, amount: -250, currency: "USD",
      name: "Manual transfer",
      entryable: Transaction.new(kind: "standard")
    )
    transfer = Transfer.create!(
      outflow_transaction: outflow_entry.entryable,
      inflow_transaction: inflow_entry.entryable
    )

    rt = RecurringTransaction.create_from_transfer(transfer)

    assert rt.transfer?
    assert_equal source, rt.account
    assert_equal destination, rt.destination_account
    assert_equal 250, rt.amount
    assert_equal "USD", rt.currency
    assert_equal 5.days.ago.to_date.day, rt.expected_day_of_month
    assert rt.manual?
    assert_equal "active", rt.status
  end

  test "projected_entry exposes source and destination on a recurring transfer" do
    destination = accounts(:credit_card)
    rt = @family.recurring_transactions.create!(
      account: @account,
      destination_account: destination,
      name: "Transfer to #{destination.name}",
      amount: 500,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: Date.current,
      next_expected_date: 15.days.from_now.to_date,
      manual: true
    )

    projected = rt.projected_entry
    assert projected.transfer
    assert_equal @account, projected.source_account
    assert_equal destination, projected.destination_account
    assert_equal 500, projected.amount
    assert_equal "USD", projected.currency
  end

  test "Identifier skips transfer-kind transactions" do
    # Three depository transactions tagged as funds_movement (e.g. they're
    # one half of a Transfer pair). Identifier shouldn't latch onto these
    # as a single-account "pattern" because the underlying flow is two-
    # account and is tracked on a different shape (destination_account_id).
    [ 0, 1, 2 ].each do |months_ago|
      transaction = Transaction.create!(merchant: @merchant, kind: "funds_movement")
      @account.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 5.days,
        amount: 50.00,
        currency: "USD",
        name: "Recurring transfer half",
        entryable: transaction
      )
    end

    assert_no_difference "@family.recurring_transactions.count" do
      RecurringTransaction.identify_patterns_for!(@family)
    end
  end

  test "Identifier creates a pattern from expense halves while ignoring co-resident transfer halves" do
    # Same merchant, amount, day-of-month: 3 standard expenses + 3 transfer halves.
    # Without the TRANSFER_KINDS filter, the identifier would either double-count
    # (six occurrences) or surface a weird pattern. With the filter, only the
    # expense pattern is created.
    [ 0, 1, 2 ].each do |months_ago|
      base_date = months_ago.months.ago.beginning_of_month + 5.days

      @account.entries.create!(
        date: base_date, amount: 50.00, currency: "USD", name: "Coffee",
        entryable: Transaction.create!(merchant: @merchant, kind: "standard")
      )
      @account.entries.create!(
        date: base_date, amount: 50.00, currency: "USD", name: "Half of transfer",
        entryable: Transaction.create!(merchant: @merchant, kind: "funds_movement")
      )
    end

    assert_difference "@family.recurring_transactions.count", 1 do
      RecurringTransaction.identify_patterns_for!(@family)
    end
    assert_nil @family.recurring_transactions.last.destination_account_id
  end

  test "create_from_transfer name reflects Transfer#name (Payment vs Transfer based on destination)" do
    # Transfer#name returns "Payment to ..." for liability destinations
    # and "Transfer to ..." otherwise, mirroring Transfer::Creator's
    # name_prefix logic. The recurring row should pick that up rather
    # than hard-coding "Transfer to ...".
    source = @account
    cc_destination = accounts(:credit_card) # liability
    outflow = source.entries.create!(
      date: 5.days.ago.to_date, amount: 100, currency: "USD",
      name: "raw", entryable: Transaction.new(kind: "standard")
    )
    inflow = cc_destination.entries.create!(
      date: 5.days.ago.to_date, amount: -100, currency: "USD",
      name: "raw", entryable: Transaction.new(kind: "standard")
    )
    transfer = Transfer.create!(
      outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable
    )

    rt = RecurringTransaction.create_from_transfer(transfer)
    assert_equal "Payment to #{cc_destination.name}", rt.name
  end

  test "create_from_transfer stores source-side currency on multi-currency transfers" do
    source = @account # USD depository
    destination = @family.accounts.create!(
      name: "EUR cash", balance: 0, currency: "EUR", accountable: Depository.new
    )
    outflow_entry = source.entries.create!(
      date: 5.days.ago.to_date, amount: 100, currency: "USD",
      name: "FX transfer", entryable: Transaction.new(kind: "standard")
    )
    inflow_entry = destination.entries.create!(
      date: 5.days.ago.to_date, amount: -92, currency: "EUR",
      name: "FX transfer", entryable: Transaction.new(kind: "standard")
    )
    transfer = Transfer.create!(
      outflow_transaction: outflow_entry.entryable,
      inflow_transaction: inflow_entry.entryable
    )

    rt = RecurringTransaction.create_from_transfer(transfer)
    assert_equal "USD", rt.currency, "stores source-side currency"
    assert_equal 100, rt.amount,    "stores source-side amount"
  end

  test "destroying the destination account cascades to inbound recurring transfers" do
    source = @account
    destination = accounts(:credit_card)
    rt = @family.recurring_transactions.create!(
      account: source, destination_account: destination,
      name: "Transfer to CC", amount: 250, currency: "USD",
      expected_day_of_month: 1, last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date, manual: true
    )

    assert_difference -> { RecurringTransaction.count }, -1 do
      destination.destroy
    end
    assert_not RecurringTransaction.exists?(rt.id)
  end

  test "Cleaner skips recurring transfers so they aren't mistakenly marked inactive" do
    # `matching_transactions` is single-account name/amount-based and never
    # matches a Transfer pair, so without the skip the recurring transfer
    # would flip to inactive at the 6-month threshold even when the user
    # is still doing the transfer monthly. Issue #1590 tracks the proper
    # pair-detection fix.
    rt = @family.recurring_transactions.create!(
      account: @account, destination_account: accounts(:credit_card),
      name: "Transfer to CC", amount: 250, currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: 7.months.ago.to_date,
      next_expected_date: 5.days.from_now.to_date,
      manual: true
    )
    assert rt.should_be_inactive?, "guard sanity: row would be marked inactive without the skip"

    RecurringTransaction.cleanup_stale_for(@family)
    assert_equal "active", rt.reload.status
  end

  test "Identifier#update_manual_recurring_transactions skips recurring transfers" do
    # Same reasoning as the Cleaner skip. Without the guard, the helper
    # would call find_matching_transaction_entries (single-account, by
    # name) on a transfer row and silently overwrite its variance /
    # occurrence_count with []. The variance fields should stay nil.
    rt = @family.recurring_transactions.create!(
      account: @account, destination_account: accounts(:credit_card),
      name: "Transfer to CC", amount: 500, currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      manual: true,
      occurrence_count: 7
    )

    RecurringTransaction.identify_patterns_for!(@family)

    rt.reload
    assert_nil rt.expected_amount_min
    assert_nil rt.expected_amount_max
    assert_nil rt.expected_amount_avg
    assert_equal 7, rt.occurrence_count, "occurrence_count must not be overwritten by the manual-recurring update path"
  end

  test "unique partial index still de-duplicates non-transfer recurring rows after destination widening" do
    base_attrs = {
      account: @account,
      merchant: @merchant,
      amount: 15.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      manual: false,
      occurrence_count: 3
    }
    @family.recurring_transactions.create!(base_attrs)

    assert_raises(ActiveRecord::RecordNotUnique) do
      @family.recurring_transactions.create!(base_attrs)
    end
  end
end
