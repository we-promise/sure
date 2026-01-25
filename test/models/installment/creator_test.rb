require "test_helper"

class Installment::CreatorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @source_account = @family.accounts.create!(
      name: "Checking",
      balance: 5000,
      currency: "USD",
      accountable: Depository.new
    )
  end

  def create_installment_account(installment_attrs)
    @family.accounts.create!(
      name: "Installment Account",
      balance: 0,
      currency: "USD",
      accountable: Installment.new(installment_attrs)
    )
  end

  test "generates correct number of historical transactions for future dates" do
    account = create_installment_account(
      installment_cost: 200, total_term: 6, current_term: 3,
      payment_period: "monthly", first_payment_date: Date.current
    )

    assert_difference "account.transactions.count", 3 do
      Installment::Creator.new(account.accountable).call
    end
  end

  test "does not generate historical transactions for past dates" do
    account = create_installment_account(
      installment_cost: 200, total_term: 6, current_term: 3,
      payment_period: "monthly", first_payment_date: 6.months.ago.to_date
    )

    assert_no_difference "account.transactions.count" do
      Installment::Creator.new(account.accountable).call
    end
  end

  test "creates no historical transactions when current_term is 0" do
    account = create_installment_account(
      installment_cost: 200, total_term: 6, current_term: 0,
      payment_period: "monthly", first_payment_date: Date.current
    )

    assert_no_difference "account.transactions.count" do
      Installment::Creator.new(account.accountable).call
    end
  end

  test "historical transactions have correct dates based on payment schedule" do
    first_payment = Date.current
    account = create_installment_account(
      installment_cost: 200, total_term: 3, current_term: 3,
      payment_period: "monthly", first_payment_date: first_payment
    )

    Installment::Creator.new(account.accountable).call

    transactions = account.transactions.order("entries.date")
    assert_equal 3, transactions.count
    assert_equal first_payment, transactions.first.entry.date
    assert_equal first_payment + 1.month, transactions.second.entry.date
    assert_equal first_payment + 2.months, transactions.third.entry.date
  end

  test "historical transactions are linked to installment via extra" do
    account = create_installment_account(
      installment_cost: 200, total_term: 3, current_term: 2,
      payment_period: "monthly", first_payment_date: Date.current
    )
    installment = account.accountable

    Installment::Creator.new(installment).call

    assert account.transactions.count > 0, "Expected transactions to be created"
    account.transactions.each do |transaction|
      assert_equal installment.id.to_s, transaction.extra["installment_id"]
      assert transaction.extra["installment_payment_number"].present?
    end
  end

  test "historical transactions are created as loan_payment" do
    account = create_installment_account(
      installment_cost: 200, total_term: 3, current_term: 2,
      payment_period: "monthly", first_payment_date: Date.current
    )

    Installment::Creator.new(account.accountable).call

    assert account.transactions.count > 0, "Expected transactions to be created"
    account.transactions.each do |transaction|
      assert_equal "loan_payment", transaction.kind
    end
  end

  test "creates recurring transaction when source_account_id provided" do
    account = create_installment_account(
      installment_cost: 200, total_term: 6, current_term: 0,
      payment_period: "monthly", first_payment_date: Date.current
    )
    installment = account.accountable

    assert_difference "RecurringTransaction.count", 1 do
      Installment::Creator.new(installment, source_account_id: @source_account.id).call
    end

    recurring_transaction = RecurringTransaction.find_by(installment_id: installment.id)
    assert_not_nil recurring_transaction
    assert_equal installment.id, recurring_transaction.installment_id
    assert_equal -200, recurring_transaction.amount
    assert_equal "USD", recurring_transaction.currency
    assert recurring_transaction.active?
  end

  test "does not create recurring transaction when source_account_id not provided" do
    account = create_installment_account(
      installment_cost: 200, total_term: 6, current_term: 0,
      payment_period: "monthly", first_payment_date: Date.current
    )

    assert_no_difference "RecurringTransaction.count" do
      Installment::Creator.new(account.accountable).call
    end
  end

  test "updates account balance to calculated current balance" do
    account = create_installment_account(
      installment_cost: 200, total_term: 6, current_term: 3,
      payment_period: "monthly", first_payment_date: 6.months.ago.to_date
    )
    installment = account.accountable

    Installment::Creator.new(installment).call

    account.reload
    assert_equal installment.calculate_current_balance, account.balance
  end

  test "creates balance record for today" do
    account = create_installment_account(
      installment_cost: 200, total_term: 6, current_term: 3,
      payment_period: "monthly", first_payment_date: 6.months.ago.to_date
    )
    installment = account.accountable

    assert_difference "account.balances.count", 1 do
      Installment::Creator.new(installment).call
    end

    balance = account.balances.find_by(date: Date.current)
    assert_not_nil balance
    assert_equal installment.calculate_current_balance, balance.balance
  end
end
