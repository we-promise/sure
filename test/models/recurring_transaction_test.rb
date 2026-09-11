require "test_helper"

class RecurringTransactionTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @merchant = merchants(:netflix)
    @account = accounts(:depository)
    # Clear any existing recurring transactions
    @family.recurring_transactions.destroy_all
  end

  test "payable ignores a debt destination that belongs to another family" do
    foreign_card = families(:empty).accounts.create!(
      name: "Foreign Card", balance: 0, currency: "USD", accountable: CreditCard.new
    )
    transfer = @family.recurring_transactions.create!(
      name: "Card payment", account: @account, amount: 200, currency: "USD",
      expected_day_of_month: 5, last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date, status: "active", manual: true
    )
    transfer.update_column(:destination_account_id, foreign_card.id)

    assert_not_includes @family.recurring_transactions.payable, transfer,
      "a destination outside the family is not this family's obligation"
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

  # end_after_count is a permitted parameter and the generator materialises a
  # finite plan whole, so an absurd value is not a silly setting: it is one
  # request deciding how far the table grows. 100,000 wrote 100,000 rows.
  test "an absurd installment plan length is refused before any row is written" do
    plan = build_recurring(bill_type: "installment", end_mode: "after_count",
                                  end_after_count: 100_000)

    assert_not plan.valid?
    assert_includes plan.errors.attribute_names, :end_after_count
  end

  test "a realistic installment plan length is accepted" do
    plan = build_recurring(bill_type: "installment", end_mode: "after_count",
                                  end_after_count: 24, anchor_date: Date.current)

    assert plan.valid?, plan.errors.full_messages.to_sentence
  end

  # category_id is permitted too, and nothing checked whose category it was.
  test "a category belonging to another family is refused" do
    other = Family.create!(name: "Other Household", currency: "USD")
    foreign = Category.create!(family: other, name: "Their Groceries", color: "#ff0000")

    bill = build_recurring(category_id: foreign.id)

    assert_not bill.valid?
    assert_includes bill.errors.attribute_names, :category_id
  end

  test "a category belonging to this family is accepted" do
    own = Category.create!(family: @family, name: "Our Groceries", color: "#00ff00")

    bill = build_recurring(category_id: own.id)

    assert bill.valid?, bill.errors.full_messages.to_sentence
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
    assert_equal "suggested", recurring.status
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
    assert_equal "suggested", recurring.status
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
    assert_equal "suggested", recurring.status
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

  test "matching_transactions rejects a same-day charge in an off-cycle month" do
    recurring = build_recurring(
      merchant: nil,
      name: "Quarterly water bill",
      amount: 90.00,
      anchor_date: Date.new(2026, 5, 15),
      last_occurrence_date: Date.new(2026, 5, 15),
      next_expected_date: Date.new(2026, 8, 15)
    )
    recurring.save!
    recurring.recurrence_rules.create!(frequency: "monthly", interval: 3, day_of_month: 15)

    entries = [ Date.new(2026, 8, 15), Date.new(2026, 7, 15) ].map do |date|
      @account.entries.create!(
        date: date,
        amount: 90.00,
        currency: "USD",
        name: "Quarterly water bill",
        entryable: Transaction.create!
      )
    end
    on_cycle, off_cycle = entries

    matches = recurring.matching_transactions.map(&:id)
    # Positive control: the on-cycle month's charge still matches.
    assert_includes matches, on_cycle.id
    # Same calendar day, off-cycle month: the day window alone would accept it.
    assert_not_includes matches, off_cycle.id
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

  test "create_from_transaction does not blend a distinct same-day charge type into the variance band" do
    # Mirrors a real production case: two genuinely different charges from
    # the same merchant, same day (a small fee alongside a larger due),
    # ~6.5x apart -- not one fluctuating payment.
    fee_transaction = Transaction.create!(merchant: @merchant, category: categories(:food_and_drink))
    fee_entry = @account.entries.create!(
      date: 1.month.ago.beginning_of_month + 14.days,
      amount: 3.00,
      currency: "USD",
      name: "Test Transaction",
      entryable: fee_transaction
    )

    due_transaction = Transaction.create!(merchant: @merchant, category: categories(:food_and_drink))
    @account.entries.create!(
      date: 1.month.ago.beginning_of_month + 14.days,
      amount: 19.68,
      currency: "USD",
      name: "Test Transaction",
      entryable: due_transaction
    )

    recurring = RecurringTransaction.create_from_transaction(fee_entry.transaction)

    assert_equal 3.00, recurring.expected_amount_min
    assert_equal 3.00, recurring.expected_amount_max
    assert_equal 3.00, recurring.expected_amount_avg
    assert_equal 1, recurring.occurrence_count
  end

  test "create_from_transaction collides on an identical series and still forks a different price tier" do
    first_transaction = Transaction.create!(merchant: @merchant, category: categories(:food_and_drink))
    @account.entries.create!(
      date: 2.months.ago,
      amount: 50.00,
      currency: "USD",
      name: "Test Transaction",
      entryable: first_transaction
    )

    recurring = RecurringTransaction.create_from_transaction(first_transaction)
    assert_equal "50.0", recurring.dedup_scope, "the amount is stamped before the first insert"

    # An identical series (same identity, same amount) must hit the unique
    # index on the first insert, not slip past it as a stamped duplicate.
    duplicate_transaction = Transaction.create!(merchant: @merchant, category: categories(:food_and_drink))
    @account.entries.create!(
      date: 1.month.ago,
      amount: 50.00,
      currency: "USD",
      name: "Test Transaction",
      entryable: duplicate_transaction
    )

    assert_no_difference "@family.recurring_transactions.count" do
      assert_raises ActiveRecord::RecordNotUnique do
        RecurringTransaction.create_from_transaction(duplicate_transaction)
      end
    end

    # A different amount is a legitimate second tier from the same biller and
    # still forks a sibling series.
    tier_transaction = Transaction.create!(merchant: @merchant, category: categories(:food_and_drink))
    @account.entries.create!(
      date: 1.month.ago,
      amount: 80.00,
      currency: "USD",
      name: "Test Transaction",
      entryable: tier_transaction
    )

    assert_difference "@family.recurring_transactions.count", 1 do
      tier = RecurringTransaction.create_from_transaction(tier_transaction)
      assert_equal "80.0", tier.dedup_scope
    end
  end

  test "amount_within_variance_band? allows up to 2x and excludes beyond" do
    assert RecurringTransaction.amount_within_variance_band?(199, 100)
    assert_not RecurringTransaction.amount_within_variance_band?(201, 100)
    assert RecurringTransaction.amount_within_variance_band?(50, 100) # halved is still within band
    assert_not RecurringTransaction.amount_within_variance_band?(49, 100)
  end

  test "amount_within_variance_band? handles a zero anchor without dividing by zero" do
    assert RecurringTransaction.amount_within_variance_band?(0, 0)
    assert_not RecurringTransaction.amount_within_variance_band?(5, 0)
  end

  test "amount_within_variance_band? does not match across a sign mismatch" do
    assert_not RecurringTransaction.amount_within_variance_band?(50, -50)
    assert_not RecurringTransaction.amount_within_variance_band?(-10, 100)
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

    # Auto recurring - 2 months threshold. A second series on the same
    # identity carries a dedup_scope discriminator now that amount is no
    # longer part of the unique indexes.
    auto_recurring = @family.recurring_transactions.create!(
      account: @account,
      merchant: @merchant,
      amount: 60.00,
      dedup_scope: "60.0",
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

  test "identify_patterns_for does not re-blend a distinct charge type into an existing manual recurring transaction" do
    # Mirrors the real production corruption: a manual recurring row seeded
    # at 3.00 must not have its variance widened by a same-day, same-merchant
    # 19.68 entry when the periodic identification job runs.
    manual_recurring = @family.recurring_transactions.create!(
      account: @account,
      merchant: @merchant,
      amount: 3.00,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: 3.months.ago,
      next_expected_date: 1.month.from_now,
      status: "active",
      manual: true,
      occurrence_count: 1,
      expected_amount_min: 3.00,
      expected_amount_max: 3.00,
      expected_amount_avg: 3.00
    )

    fee_transaction = Transaction.create!(merchant: @merchant, category: categories(:food_and_drink))
    @account.entries.create!(
      date: 1.month.ago.beginning_of_month + 14.days,
      amount: 3.00,
      currency: "USD",
      name: "Test Transaction",
      entryable: fee_transaction
    )

    due_transaction = Transaction.create!(merchant: @merchant, category: categories(:food_and_drink))
    @account.entries.create!(
      date: 1.month.ago.beginning_of_month + 14.days,
      amount: 19.68,
      currency: "USD",
      name: "Test Transaction",
      entryable: due_transaction
    )

    assert_no_difference "@family.recurring_transactions.count" do
      RecurringTransaction.identify_patterns_for!(@family)
    end

    manual_recurring.reload
    assert_equal 3.00, manual_recurring.expected_amount_min
    assert_equal 3.00, manual_recurring.expected_amount_max
    assert_equal 3.00, manual_recurring.expected_amount_avg
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

  test "validation rejects a source account from a different family" do
    other_family = Family.create!(name: "Other", locale: "en", date_format: "%Y-%m-%d", currency: "USD")
    other_account = other_family.accounts.create!(name: "Other depository", balance: 0, currency: "USD", accountable: Depository.new)

    rt = build_recurring(account: other_account)

    assert_not rt.valid?
    assert_includes rt.errors[:account], "must belong to this family"
  end

  test "validation rejects a transfer whose endpoints both sit in another family" do
    # The endpoint pair is internally consistent here, so only the check
    # against the bill's own family can catch it.
    other_family = Family.create!(name: "Other", locale: "en", date_format: "%Y-%m-%d", currency: "USD")
    other_source = other_family.accounts.create!(name: "Other depository", balance: 0, currency: "USD", accountable: Depository.new)
    other_destination = other_family.accounts.create!(name: "Other card", balance: 0, currency: "USD", accountable: CreditCard.new)

    rt = @family.recurring_transactions.build(
      account: other_source,
      destination_account: other_destination,
      name: "Foreign transfer pair",
      amount: 100,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date,
      manual: true
    )

    assert_not rt.valid?
    assert_includes rt.errors[:account], "must belong to this family"
    assert_includes rt.errors[:destination_account], "must belong to this family"
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

  test "Cleaner keeps a recurring transfer active when its pair still occurs (issue #1590)" do
    # The seed name rarely matches future occurrences, so pair detection (not
    # name matching) is what keeps a live transfer active past the threshold.
    rt = @family.recurring_transactions.create!(
      account: @account, destination_account: accounts(:credit_card),
      name: "Transfer to CC", amount: 250, currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: 7.months.ago.to_date,
      next_expected_date: 5.days.from_now.to_date,
      manual: true
    )
    assert rt.should_be_inactive?, "guard sanity: stale last_occurrence_date"

    # A fresh transfer pair this cycle, carrying a *different* free-text name.
    date = 1.month.ago.beginning_of_month + 4.days # day-of-month 5
    outflow = @account.entries.create!(
      date: date, amount: 250, currency: "USD", name: "rent transfer",
      entryable: Transaction.new(kind: "funds_movement")
    )
    inflow = accounts(:credit_card).entries.create!(
      date: date, amount: -250, currency: "USD", name: "rent transfer",
      entryable: Transaction.new(kind: "funds_movement")
    )
    Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable)

    RecurringTransaction.cleanup_stale_for(@family)
    assert_equal "active", rt.reload.status
  end

  test "Cleaner retires a recurring transfer whose pair has stopped" do
    # No matching Transfer pair → genuinely stale → should be retired. This is
    # the correctness the pair-detection (vs the old blanket skip) buys us.
    rt = @family.recurring_transactions.create!(
      account: @account, destination_account: accounts(:credit_card),
      name: "Transfer to CC", amount: 250, currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: 7.months.ago.to_date,
      next_expected_date: 5.days.from_now.to_date,
      manual: true
    )

    RecurringTransaction.cleanup_stale_for(@family)
    assert_equal "inactive", rt.reload.status
  end

  test "matching_transactions finds the transfer pair regardless of occurrence name" do
    rt = @family.recurring_transactions.create!(
      account: @account, destination_account: accounts(:credit_card),
      name: "Transfer to CC", amount: 250, currency: "USD",
      expected_day_of_month: 5, last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date, manual: true
    )
    date = Date.current.beginning_of_month + 4.days # day-of-month 5
    outflow = @account.entries.create!(
      date: date, amount: 250, currency: "USD", name: "an importer's wording",
      entryable: Transaction.new(kind: "funds_movement")
    )
    inflow = accounts(:credit_card).entries.create!(
      date: date, amount: -250, currency: "USD", name: "an importer's wording",
      entryable: Transaction.new(kind: "funds_movement")
    )
    Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable)

    assert_includes rt.matching_transactions.map(&:id), outflow.id
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

  # The scheme allowlist is the security boundary for payment_url: the value is
  # rendered as a link, so a "javascript:" or "data:" scheme surviving to the view
  # would be stored XSS. These cases are the contract, not incidental coverage.
  test "payment_url rejects any scheme other than http and https" do
    [
      "javascript:alert(1)",
      "JaVaScRiPt:alert(1)",
      "  javascript:alert(1)  ",
      "data:text/html,<script>alert(1)</script>",
      "mailto:billing@example.com",
      "ftp://example.com/pay",
      "https://"
    ].each do |hostile|
      recurring = build_recurring(payment_url: hostile)

      assert_not recurring.valid?, "expected #{hostile.inspect} to be rejected"
      assert_includes recurring.errors.attribute_names, :payment_url
    end
  end

  test "payment_url accepts http and https and promotes a bare host to https" do
    {
      "https://pay.example.com/bill" => "https://pay.example.com/bill",
      "http://pay.example.com" => "http://pay.example.com",
      "pay.example.com" => "https://pay.example.com",
      "  pay.example.com  " => "https://pay.example.com",
      # A colon followed by digits is a port, not a scheme. Self-hosters link to
      # LAN services this way.
      "192.168.1.5:3000/pay" => "https://192.168.1.5:3000/pay"
    }.each do |input, expected|
      recurring = build_recurring(payment_url: input)

      assert recurring.valid?, "expected #{input.inspect} to be accepted: #{recurring.errors.full_messages}"
      assert_equal expected, recurring.payment_url
    end
  end

  test "payment_url is optional and normalizes blank to nil" do
    [ nil, "", "   " ].each do |blank|
      recurring = build_recurring(payment_url: blank)

      assert recurring.valid?
      assert_nil recurring.payment_url
    end
  end

  # `calculate_next_expected_date` jumps to `last_occurrence_date.next_month`, so a
  # payment posting earlier in the month than the expected day skips the occurrence
  # still ahead this month: rent due on the 29th, last paid on the 6th, is stored as
  # due next month. Bills must not repeat that to the user.
  test "next_due_date corrects a stored date that skipped this month's occurrence" do
    travel_to Date.new(2026, 8, 13) do
      recurring = build_recurring(
        expected_day_of_month: 29,
        last_occurrence_date: Date.new(2026, 8, 6),
        next_expected_date: Date.new(2026, 9, 29)
      )

      assert_equal Date.new(2026, 8, 29), recurring.next_due_date
      assert_not recurring.overdue?
    end
  end

  test "next_due_date leaves a correct stored date alone" do
    travel_to Date.new(2026, 8, 13) do
      recurring = build_recurring(
        expected_day_of_month: 21,
        last_occurrence_date: Date.new(2026, 7, 21),
        next_expected_date: Date.new(2026, 8, 21)
      )

      assert_equal Date.new(2026, 8, 21), recurring.next_due_date
    end
  end

  test "next_due_date does not advance an overdue bill past its due date" do
    travel_to Date.new(2026, 8, 13) do
      recurring = build_recurring(
        expected_day_of_month: 5,
        last_occurrence_date: Date.new(2026, 7, 5),
        next_expected_date: Date.new(2026, 8, 5)
      )

      assert_equal Date.new(2026, 8, 5), recurring.next_due_date
      assert recurring.overdue?
    end
  end

  test "bills scope keeps expenses and drops income, transfers and paused rows" do
    expense = build_recurring(name: "Rent", merchant: nil, amount: 1200).tap(&:save!)
    build_recurring(name: "Paycheck", merchant: nil, amount: -2000).tap(&:save!)
    build_recurring(name: "Paused", merchant: nil, amount: 40, status: "inactive").tap(&:save!)
    build_recurring(name: "Card payment", merchant: nil, amount: 500,
                    destination_account: accounts(:credit_card)).tap(&:save!)

    assert_equal [ expense.id ], @family.recurring_transactions.bills.pluck(:id)
  end

  test "display_name prefers the merchant over the free-text name" do
    assert_equal @merchant.name, build_recurring(merchant: @merchant, name: nil).display_name
    assert_equal "Rent", build_recurring(merchant: nil, name: "Rent").display_name
  end


  # next_expected_date only advances when a bank entry matches during sync, so
  # a bill settled through mark_paid!, a manual payment or the assistant froze
  # it in the past forever. next_due_date returned it verbatim, which reported
  # a fully paid bill as long overdue and answered due_within_days for a date
  # 45 days gone.
  test "a settled bill looks ahead to its next open cycle, not at a stale hint" do
    series = stale_hint_series

    series.recurring_occurrences.where("due_on <= ?", Date.current).find_each do |occurrence|
      RecurringTransaction::Allocator.new(occurrence).mark_paid!
    end
    series.reload

    assert_operator series.next_due_date, :>, Date.current,
      "every owed cycle is paid, so nothing is due in the past"
    assert_not series.overdue?
    assert_equal 0, series.cycles_overdue
  end

  test "an unpaid past cycle is still overdue" do
    series = stale_hint_series

    assert series.overdue?, "the oldest unpaid cycle is what makes a bill late"
    assert_equal series.recurring_occurrences.open_status.minimum(:due_on), series.next_due_date
  end

  # "Whole cycles" is meant literally. The old formula added one, so a bill a
  # single day late already claimed a full cycle missed.
  test "cycles_overdue counts only whole cycles elapsed" do
    series = stale_hint_series
    due = Date.current - 1
    series.recurring_occurrences.destroy_all
    series.recurring_occurrences.create!(
      family: @family, original_due_on: due, due_on: due,
      currency: "USD", expected_amount: 60, status: "scheduled"
    )

    assert series.reload.overdue?
    assert_equal 0, series.cycles_overdue, "one day late is not one cycle missed"
  end

  private

    def stale_hint_series
      stale = 45.days.ago.to_date
      series = @family.recurring_transactions.create!(
        name: "Gym #{stale}", account: accounts(:depository), amount: 60,
        currency: "USD", status: "active", bill_type: "subscription", manual: true,
        dedup_scope: "gym-#{stale}", expected_day_of_month: stale.day,
        last_occurrence_date: stale << 1, next_expected_date: stale
      )
      series.reload
    end

    def build_recurring(**overrides)
      @family.recurring_transactions.build({
        account: @account,
        merchant: @merchant,
        amount: 29.99,
        currency: "USD",
        expected_day_of_month: 15,
        last_occurrence_date: Date.current,
        next_expected_date: 1.month.from_now.to_date,
        status: "active"
      }.merge(overrides))
    end
end
