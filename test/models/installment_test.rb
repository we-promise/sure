require "test_helper"

class InstallmentTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(
      name: "Test Installment",
      balance: 1200,
      currency: "USD",
      accountable: Installment.new(
        installment_cost: 200,
        total_term: 6,
        current_term: 3,
        payment_period: "monthly",
        first_payment_date: 6.months.ago.to_date
      )
    )
    @installment = @account.accountable
  end

  test "creates valid installment as accountable type" do
    assert @installment.persisted?
    assert_equal 200, @installment.installment_cost
    assert_equal 6, @installment.total_term
    assert_equal 3, @installment.current_term
    assert_equal "monthly", @installment.payment_period
    assert_equal "Installment", @account.accountable_type
  end

  test "validates presence of required fields" do
    installment = Installment.new

    assert_not installment.valid?
    assert_includes installment.errors[:installment_cost], "can't be blank"
    assert_includes installment.errors[:total_term], "can't be blank"
    assert_includes installment.errors[:payment_period], "can't be blank"
    assert_includes installment.errors[:first_payment_date], "can't be blank"
  end

  test "validates current_term is less than or equal to total_term" do
    installment = Installment.new(
      installment_cost: 200,
      total_term: 6,
      current_term: 7,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date
    )

    assert_not installment.valid?
    assert_includes installment.errors[:current_term], "cannot be greater than total term"
  end

  test "validates positive installment_cost" do
    installment = Installment.new(
      installment_cost: -100,
      total_term: 6,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date
    )

    assert_not installment.valid?
    assert_includes installment.errors[:installment_cost], "must be greater than 0"
  end

  test "validates positive total_term" do
    installment = Installment.new(
      installment_cost: 200,
      total_term: 0,
      current_term: 0,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date
    )

    assert_not installment.valid?
    assert_includes installment.errors[:total_term], "must be greater than 0"
  end

  test "validates non-negative current_term" do
    installment = Installment.new(
      installment_cost: 200,
      total_term: 6,
      current_term: -1,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date
    )

    assert_not installment.valid?
    assert_includes installment.errors[:current_term], "must be greater than or equal to 0"
  end

  test "calculate_original_balance returns installment_cost times total_term" do
    assert_equal 1200, @installment.calculate_original_balance
  end

  test "calculate_current_balance returns full balance when current_term is 0" do
    account = @family.accounts.create!(
      name: "New Installment",
      balance: 1200,
      currency: "USD",
      accountable: Installment.new(
        installment_cost: 200,
        total_term: 6,
        current_term: 0,
        payment_period: "monthly",
        first_payment_date: Date.current
      )
    )

    assert_equal 1200, account.accountable.calculate_current_balance
  end

  test "remaining_principal_money wraps the calculated balance" do
    account = @family.accounts.create!(
      name: "New Installment",
      balance: 1200,
      currency: "USD",
      accountable: Installment.new(
        installment_cost: 200,
        total_term: 6,
        current_term: 0,
        payment_period: "monthly",
        first_payment_date: Date.current
      )
    )
    installment = account.accountable

    assert_equal Money.new(installment.calculate_current_balance, "USD"), installment.remaining_principal_money
  end

  test "calculate_current_balance returns remaining balance based on schedule" do
    expected_remaining = (@installment.total_term - @installment.payments_scheduled_to_date) * @installment.installment_cost
    assert_equal expected_remaining, @installment.calculate_current_balance
  end

  test "generate_payment_schedule creates correct number of payments" do
    schedule = @installment.generate_payment_schedule
    assert_equal 6, schedule.length
  end

  test "generate_payment_schedule has correct structure" do
    account = @family.accounts.create!(
      name: "Schedule Test",
      balance: 600,
      currency: "USD",
      accountable: Installment.new(
        installment_cost: 200,
        total_term: 3,
        current_term: 0,
        payment_period: "monthly",
        first_payment_date: Date.new(2024, 1, 15)
      )
    )
    installment = account.accountable
    schedule = installment.generate_payment_schedule

    assert_equal 1, schedule[0][:payment_number]
    assert_equal Date.new(2024, 1, 15), schedule[0][:date]
    assert_equal 200, schedule[0][:amount]

    assert_equal 2, schedule[1][:payment_number]
    assert_equal Date.new(2024, 2, 15), schedule[1][:date]

    assert_equal 3, schedule[2][:payment_number]
    assert_equal Date.new(2024, 3, 15), schedule[2][:date]
  end

  test "generate_payment_schedule handles weekly period" do
    account = @family.accounts.create!(
      name: "Weekly", balance: 200, currency: "USD",
      accountable: Installment.new(
        installment_cost: 50, total_term: 4, current_term: 0,
        payment_period: "weekly", first_payment_date: Date.new(2024, 1, 1)
      )
    )
    schedule = account.accountable.generate_payment_schedule

    assert_equal Date.new(2024, 1, 1), schedule[0][:date]
    assert_equal Date.new(2024, 1, 8), schedule[1][:date]
    assert_equal Date.new(2024, 1, 15), schedule[2][:date]
    assert_equal Date.new(2024, 1, 22), schedule[3][:date]
  end

  test "generate_payment_schedule handles bi_weekly period" do
    account = @family.accounts.create!(
      name: "Bi-weekly", balance: 300, currency: "USD",
      accountable: Installment.new(
        installment_cost: 100, total_term: 3, current_term: 0,
        payment_period: "bi_weekly", first_payment_date: Date.new(2024, 1, 1)
      )
    )
    schedule = account.accountable.generate_payment_schedule

    assert_equal Date.new(2024, 1, 1), schedule[0][:date]
    assert_equal Date.new(2024, 1, 15), schedule[1][:date]
    assert_equal Date.new(2024, 1, 29), schedule[2][:date]
  end

  test "generate_payment_schedule handles quarterly period" do
    account = @family.accounts.create!(
      name: "Quarterly", balance: 2400, currency: "USD",
      accountable: Installment.new(
        installment_cost: 600, total_term: 4, current_term: 0,
        payment_period: "quarterly", first_payment_date: Date.new(2024, 1, 1)
      )
    )
    schedule = account.accountable.generate_payment_schedule

    assert_equal Date.new(2024, 1, 1), schedule[0][:date]
    assert_equal Date.new(2024, 4, 1), schedule[1][:date]
    assert_equal Date.new(2024, 7, 1), schedule[2][:date]
    assert_equal Date.new(2024, 10, 1), schedule[3][:date]
  end

  test "generate_payment_schedule handles yearly period" do
    account = @family.accounts.create!(
      name: "Yearly", balance: 7200, currency: "USD",
      accountable: Installment.new(
        installment_cost: 2400, total_term: 3, current_term: 0,
        payment_period: "yearly", first_payment_date: Date.new(2024, 1, 1)
      )
    )
    schedule = account.accountable.generate_payment_schedule

    assert_equal Date.new(2024, 1, 1), schedule[0][:date]
    assert_equal Date.new(2025, 1, 1), schedule[1][:date]
    assert_equal Date.new(2026, 1, 1), schedule[2][:date]
  end

  test "completed? returns false when no payments recorded" do
    assert_not @installment.completed?
  end

  test "completed? returns true when all payments recorded" do
    account = @family.accounts.create!(
      name: "Complete", balance: 0, currency: "USD",
      accountable: Installment.new(
        installment_cost: 200, total_term: 3, current_term: 3,
        payment_period: "monthly", first_payment_date: 3.months.ago.to_date
      )
    )
    installment = account.accountable

    3.times do |i|
      transaction = Transaction.create!(extra: { "installment_id" => installment.id.to_s })
      account.entries.create!(
        entryable: transaction, amount: -200, currency: "USD",
        date: (3 - i).months.ago.to_date, name: "Payment #{i + 1}"
      )
    end

    assert installment.completed?
  end

  test "payments_completed counts transactions linked to installment" do
    assert_equal 0, @installment.payments_completed

    transaction = Transaction.create!(extra: { "installment_id" => @installment.id.to_s })
    @account.entries.create!(
      entryable: transaction, amount: -200, currency: "USD",
      date: Date.current, name: "Payment 1"
    )

    assert_equal 1, @installment.payments_completed
  end

  test "next_payment_date returns next upcoming payment date" do
    account = @family.accounts.create!(
      name: "Future", balance: 1200, currency: "USD",
      accountable: Installment.new(
        installment_cost: 200, total_term: 6, current_term: 0,
        payment_period: "monthly", first_payment_date: 1.month.from_now.to_date
      )
    )

    next_date = account.accountable.next_payment_date
    assert_not_nil next_date
    assert next_date > Date.current
  end

  test "next_payment_date returns nil when all payments are past" do
    account = @family.accounts.create!(
      name: "Past", balance: 0, currency: "USD",
      accountable: Installment.new(
        installment_cost: 200, total_term: 3, current_term: 3,
        payment_period: "monthly", first_payment_date: 4.months.ago.to_date
      )
    )

    assert_nil account.accountable.next_payment_date
  end

  test "payments_remaining returns correct count" do
    assert_equal 6, @installment.payments_remaining
  end

  test "currency returns account currency" do
    assert_equal "USD", @installment.currency
  end

  test "installment payment transactions use loan_payment kind" do
    # Create an installment with future payments so Creator generates transactions
    future_account = @family.accounts.create!(
      name: "Future Installment",
      balance: 1200,
      currency: "USD",
      accountable: Installment.new(
        installment_cost: 200,
        total_term: 6,
        current_term: 3,
        payment_period: "monthly",
        first_payment_date: Date.current
      )
    )
    future_installment = future_account.accountable

    Installment::Creator.new(future_installment).call

    transactions = future_account.transactions.where("extra->>'installment_id' = ?", future_installment.id.to_s)

    assert transactions.any?, "Expected installment transactions to be created"
    assert transactions.all?(&:loan_payment?), "Expected all transactions to be loan_payment kind"
  end
end
