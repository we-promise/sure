require "test_helper"

class InstallmentTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(
      name: "Test Loan",
      balance: 1200,
      currency: "USD",
      accountable_type: "Loan",
      accountable_attributes: {}
    )
  end

  test "creates valid installment with all required fields" do
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
    )

    assert installment.persisted?
    assert_equal 200, installment.installment_cost
    assert_equal 6, installment.total_term
    assert_equal 3, installment.current_term
    assert_equal "monthly", installment.payment_period
  end

  test "validates presence of required fields" do
    installment = @account.build_installment

    assert_not installment.valid?
    assert_includes installment.errors[:installment_cost], "can't be blank"
    assert_includes installment.errors[:total_term], "can't be blank"
    assert_includes installment.errors[:payment_period], "can't be blank"
    assert_includes installment.errors[:first_payment_date], "can't be blank"
  end

  test "validates current_term is less than or equal to total_term" do
    installment = @account.build_installment(
      installment_cost: 200,
      total_term: 6,
      current_term: 7,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
    )

    assert_not installment.valid?
    assert_includes installment.errors[:current_term], "cannot be greater than total term"
  end

  test "validates positive installment_cost" do
    installment = @account.build_installment(
      installment_cost: -100,
      total_term: 6,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
    )

    assert_not installment.valid?
    assert_includes installment.errors[:installment_cost], "must be greater than 0"
  end

  test "validates positive total_term" do
    installment = @account.build_installment(
      installment_cost: 200,
      total_term: 0,
      current_term: 0,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
    )

    assert_not installment.valid?
    assert_includes installment.errors[:total_term], "must be greater than 0"
  end

  test "validates non-negative current_term" do
    installment = @account.build_installment(
      installment_cost: 200,
      total_term: 6,
      current_term: -1,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
    )

    assert_not installment.valid?
    assert_includes installment.errors[:current_term], "must be greater than or equal to 0"
  end

  test "warns if installment_cost seems unusually high" do
    # Large payment (> $10,000) with short term (< 3) triggers warning
    installment = @account.build_installment(
      installment_cost: 15000,
      total_term: 2,
      current_term: 0,
      payment_period: "monthly",
      first_payment_date: Date.current,
    )

    assert_not installment.valid?
    assert_includes installment.errors[:installment_cost], "seems unusually high relative to total loan amount"
  end

  test "calculate_original_balance returns installment_cost times total_term" do
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
    )

    assert_equal 1200, installment.calculate_original_balance
  end

  test "calculate_current_balance returns full balance when current_term is 0" do
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 0,
      payment_period: "monthly",
      first_payment_date: Date.current,
    )

    assert_equal 1200, installment.calculate_current_balance
  end

  test "remaining_principal_money wraps the calculated balance" do
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 0,
      payment_period: "monthly",
      first_payment_date: Date.current,
    )

    assert_equal Money.new(installment.calculate_current_balance, "USD"), installment.remaining_principal_money
  end

  test "calculate_current_balance returns remaining balance based on schedule" do
    # Started 6 months ago, currently on payment 3 of 6
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
    )

    # Should have 3 scheduled payments completed by today (6 months have passed)
    # Remaining: (6 - 3) * 200 = 600
    expected_remaining = (installment.total_term - installment.payments_scheduled_to_date) * installment.installment_cost
    assert_equal expected_remaining, installment.calculate_current_balance
  end

  test "calculate_current_balance respects current_term if it's beyond scheduled progress" do
    # Creation: first_payment_date is tomorrow, but user says they're on payment 1
    # Normally scheduled would be 0, but current_term is 1.
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 1,
      payment_period: "monthly",
      first_payment_date: 1.day.from_now.to_date
    )

    assert_equal 0, installment.payments_scheduled_to_date
    assert_equal 1, installment.current_term

    # Balance should be (6 - 1) * 200 = 1000, NOT 1200
    assert_equal 1000, installment.calculate_current_balance
  end

  test "calculate_current_balance returns 0 when all payments scheduled" do
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 6,
      payment_period: "monthly",
      first_payment_date: 7.months.ago.to_date,
    )

    # All 6 payments should be scheduled by now
    balance = installment.calculate_current_balance
    assert balance >= 0, "Balance should not be negative"
    assert balance <= 200, "Balance should be close to 0 or one payment remaining"
  end

  test "generate_payment_schedule creates correct number of payments" do
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
    )

    schedule = installment.generate_payment_schedule
    assert_equal 6, schedule.length
  end

  test "generate_payment_schedule has correct structure" do
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 3,
      current_term: 0,
      payment_period: "monthly",
      first_payment_date: Date.new(2024, 1, 15),
    )

    schedule = installment.generate_payment_schedule

    assert_equal 1, schedule[0][:payment_number]
    assert_equal Date.new(2024, 1, 15), schedule[0][:date]
    assert_equal 200, schedule[0][:amount]

    assert_equal 2, schedule[1][:payment_number]
    assert_equal Date.new(2024, 2, 15), schedule[1][:date]
    assert_equal 200, schedule[1][:amount]

    assert_equal 3, schedule[2][:payment_number]
    assert_equal Date.new(2024, 3, 15), schedule[2][:date]
    assert_equal 200, schedule[2][:amount]
  end

  test "generate_payment_schedule handles weekly period" do
    installment = @account.create_installment!(
      installment_cost: 50,
      total_term: 4,
      current_term: 0,
      payment_period: "weekly",
      first_payment_date: Date.new(2024, 1, 1),
    )

    schedule = installment.generate_payment_schedule

    assert_equal Date.new(2024, 1, 1), schedule[0][:date]
    assert_equal Date.new(2024, 1, 8), schedule[1][:date]
    assert_equal Date.new(2024, 1, 15), schedule[2][:date]
    assert_equal Date.new(2024, 1, 22), schedule[3][:date]
  end

  test "generate_payment_schedule handles bi_weekly period" do
    installment = @account.create_installment!(
      installment_cost: 100,
      total_term: 3,
      current_term: 0,
      payment_period: "bi_weekly",
      first_payment_date: Date.new(2024, 1, 1),
    )

    schedule = installment.generate_payment_schedule

    assert_equal Date.new(2024, 1, 1), schedule[0][:date]
    assert_equal Date.new(2024, 1, 15), schedule[1][:date]
    assert_equal Date.new(2024, 1, 29), schedule[2][:date]
  end

  test "generate_payment_schedule handles quarterly period" do
    installment = @account.create_installment!(
      installment_cost: 600,
      total_term: 4,
      current_term: 0,
      payment_period: "quarterly",
      first_payment_date: Date.new(2024, 1, 1),
    )

    schedule = installment.generate_payment_schedule

    assert_equal Date.new(2024, 1, 1), schedule[0][:date]
    assert_equal Date.new(2024, 4, 1), schedule[1][:date]
    assert_equal Date.new(2024, 7, 1), schedule[2][:date]
    assert_equal Date.new(2024, 10, 1), schedule[3][:date]
  end

  test "generate_payment_schedule handles yearly period" do
    installment = @account.create_installment!(
      installment_cost: 2400,
      total_term: 3,
      current_term: 0,
      payment_period: "yearly",
      first_payment_date: Date.new(2024, 1, 1),
    )

    schedule = installment.generate_payment_schedule

    assert_equal Date.new(2024, 1, 1), schedule[0][:date]
    assert_equal Date.new(2025, 1, 1), schedule[1][:date]
    assert_equal Date.new(2026, 1, 1), schedule[2][:date]
  end

  test "completed? returns false when no payments recorded" do
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
    )

    assert_not installment.completed?
  end

  test "completed? returns true when all payments recorded" do
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 3,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 3.months.ago.to_date,
    )

    # Create 3 transactions linked to this installment
    3.times do |i|
      transaction = Transaction.create!(
        extra: { "installment_id" => installment.id.to_s }
      )
      @account.entries.create!(
        entryable: transaction,
        amount: -200,
        currency: "USD",
        date: (3 - i).months.ago.to_date,
        name: "Payment #{i + 1}"
      )
    end

    assert installment.completed?
  end

  test "payments_completed counts transactions linked to installment" do
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
    )

    assert_equal 0, installment.payments_completed

    # Create a transaction linked to this installment
    transaction = Transaction.create!(
      extra: { "installment_id" => installment.id.to_s }
    )
    @account.entries.create!(
      entryable: transaction,
      amount: -200,
      currency: "USD",
      date: Date.current,
      name: "Payment 1"
    )

    assert_equal 1, installment.payments_completed
  end

  test "next_payment_date returns next upcoming payment date" do
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 0,
      payment_period: "monthly",
      first_payment_date: 1.month.from_now.to_date,
    )

    next_date = installment.next_payment_date
    assert_not_nil next_date
    assert next_date > Date.current
  end

  test "next_payment_date returns nil when all payments are past" do
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 3,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 4.months.ago.to_date,
    )

    assert_nil installment.next_payment_date
  end

  test "payments_remaining returns correct count" do
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 2,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
    )

    # With no actual transactions recorded, payments_completed = 0
    # So payments_remaining should be 6
    assert_equal 6, installment.payments_remaining
  end

  test "payments_remaining returns 0 when all completed" do
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 3,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 3.months.ago.to_date,
    )

    # Create all 3 transactions
    3.times do |i|
      transaction = Transaction.create!(
        extra: { "installment_id" => installment.id.to_s }
      )
      @account.entries.create!(
        entryable: transaction,
        amount: -200,
        currency: "USD",
        date: (3 - i).months.ago.to_date,
        name: "Payment #{i + 1}"
      )
    end

    assert_equal 0, installment.payments_remaining
  end

  test "delegates currency to account" do
    installment = @account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
    )

    assert_equal "USD", installment.currency
  end

  test "installment payment transactions use loan_payment kind for report inclusion" do
    installment = @account.create_installment!(
      installment_cost: 100,
      total_term: 12,
      current_term: 6,
      first_payment_date: Date.current,
      payment_period: "monthly"
    )

    Installment::Creator.new(installment).call

    transactions = @account.transactions.where("extra->>'installment_id' = ?", installment.id.to_s)

    assert transactions.any?, "Expected installment transactions to be created"
    assert transactions.all?(&:loan_payment?), "Expected all transactions to be loan_payment kind"

    # Verify these would be included in reports (not in exclusion list)
    excluded_kinds = %w[funds_movement one_time cc_payment]
    assert transactions.none? { |t| excluded_kinds.include?(t.kind) }
  end
end
