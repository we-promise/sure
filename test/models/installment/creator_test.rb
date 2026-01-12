require "test_helper"

class Installment::CreatorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @loan_account = @family.accounts.create!(
      name: "Car Loan",
      balance: 0,
      currency: "USD",
      accountable_type: "Loan",
      accountable_attributes: {}
    )
    @source_account = @family.accounts.create!(
      name: "Checking",
      balance: 5000,
      currency: "USD",
      accountable_type: "Depository",
      accountable_attributes: {}
    )
  end

  test "generates correct number of historical transactions" do
    installment = @loan_account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
      most_recent_payment_date: Date.current
    )

    assert_difference "@loan_account.transactions.count", 3 do
      Installment::Creator.new(installment).call
    end
  end

  test "creates no historical transactions when current_term is 0" do
    installment = @loan_account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 0,
      payment_period: "monthly",
      first_payment_date: Date.current,
      most_recent_payment_date: Date.current
    )

    assert_no_difference "@loan_account.transactions.count" do
      Installment::Creator.new(installment).call
    end
  end

  test "historical transactions have correct dates based on payment schedule" do
    installment = @loan_account.create_installment!(
      installment_cost: 200,
      total_term: 3,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: Date.new(2024, 1, 15),
      most_recent_payment_date: Date.new(2024, 3, 15)
    )

    Installment::Creator.new(installment).call

    transactions = @loan_account.transactions.order("entries.date")
    assert_equal 3, transactions.count
    assert_equal Date.new(2024, 1, 15), transactions.first.entry.date
    assert_equal Date.new(2024, 2, 15), transactions.second.entry.date
    assert_equal Date.new(2024, 3, 15), transactions.third.entry.date
  end

  test "historical transactions are linked to installment via extra" do
    installment = @loan_account.create_installment!(
      installment_cost: 200,
      total_term: 3,
      current_term: 2,
      payment_period: "monthly",
      first_payment_date: 3.months.ago.to_date,
      most_recent_payment_date: Date.current
    )

    Installment::Creator.new(installment).call

    @loan_account.transactions.each do |transaction|
      assert_equal installment.id.to_s, transaction.extra["installment_id"]
      assert transaction.extra["installment_payment_number"].present?
    end
  end

  test "creates recurring transaction when source_account_id provided" do
    installment = @loan_account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 0,
      payment_period: "monthly",
      first_payment_date: Date.current,
      most_recent_payment_date: Date.current
    )

    assert_difference "RecurringTransaction.count", 1 do
      Installment::Creator.new(installment, source_account_id: @source_account.id).call
    end

    recurring_transaction = RecurringTransaction.last
    assert_equal installment.id, recurring_transaction.installment_id
    assert_equal -200, recurring_transaction.amount
    assert_equal "USD", recurring_transaction.currency
    assert recurring_transaction.active?
  end

  test "does not create recurring transaction when source_account_id not provided" do
    installment = @loan_account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 0,
      payment_period: "monthly",
      first_payment_date: Date.current,
      most_recent_payment_date: Date.current
    )

    assert_no_difference "RecurringTransaction.count" do
      Installment::Creator.new(installment).call
    end
  end

  test "updates account balance to calculated current balance" do
    installment = @loan_account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
      most_recent_payment_date: Date.current
    )

    Installment::Creator.new(installment).call

    @loan_account.reload
    assert_equal installment.calculate_current_balance, @loan_account.balance
  end

  test "creates balance record for today" do
    installment = @loan_account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
      most_recent_payment_date: Date.current
    )

    assert_difference "@loan_account.balances.count", 1 do
      Installment::Creator.new(installment).call
    end

    balance = @loan_account.balances.find_by(date: Date.current)
    assert_not_nil balance
    assert_equal installment.calculate_current_balance, balance.balance
  end

  test "runs all operations in a transaction" do
    installment = @loan_account.create_installment!(
      installment_cost: 200,
      total_term: 6,
      current_term: 3,
      payment_period: "monthly",
      first_payment_date: 6.months.ago.to_date,
      most_recent_payment_date: Date.current
    )

    # Force an error by making the account invalid
    @loan_account.update_column(:currency, nil)

    assert_raises ActiveRecord::RecordInvalid do
      Installment::Creator.new(installment).call
    end

    # Verify no historical transactions were created due to rollback
    assert_equal 0, @loan_account.transactions.count
  end
end
