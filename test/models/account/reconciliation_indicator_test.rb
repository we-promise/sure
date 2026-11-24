require "test_helper"

class Account::ReconciliationIndicatorTest < ActiveSupport::TestCase
  setup do
    @account = families(:empty).accounts.create!(
      name: "Reconciliation account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
  end

  test "is matched when every transaction is reconciled" do
    entry = @account.entries.create!(
      name: "Reconciled transaction",
      amount: 25,
      currency: @account.currency,
      date: Date.current,
      entryable: Transaction.new
    )
    entry.update!(reconciled_status: "reconciled")

    assert_equal :matched, Account::ReconciliationIndicator.for_accounts([ @account ])[@account.id]
  end

  test "is matched when the latest statement reconciles to the account balance" do
    Account.stubs(:manual).returns(Account.where.not(id: @account.id))
    period_end = Date.new(2026, 1, 31)
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2026-01-31,100\n")
    )
    statement.update!(period_start_on: Date.new(2026, 1, 1), period_end_on: period_end, closing_balance: 100)
    @account.balances.create!(
      date: period_end,
      balance: 100,
      currency: @account.currency,
      cash_inflows: 100
    )

    assert_equal :matched, Account::ReconciliationIndicator.for_accounts([ @account ])[@account.id]
  end

  test "needs attention for an unreconciled transaction after a matched statement period" do
    Account.stubs(:manual).returns(Account.where.not(id: @account.id))
    period_end = Date.new(2026, 1, 31)
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2026-01-31,100\n")
    )
    statement.update!(period_start_on: Date.new(2026, 1, 1), period_end_on: period_end, closing_balance: 100)
    @account.balances.create!(date: period_end, balance: 100, currency: @account.currency, cash_inflows: 100)
    @account.entries.create!(
      name: "February transaction",
      amount: 25,
      currency: @account.currency,
      date: Date.new(2026, 2, 1),
      entryable: Transaction.new
    )

    assert_equal :needs_attention, Account::ReconciliationIndicator.for_accounts([ @account ])[@account.id]
  end

  test "needs attention when a transaction is unreconciled" do
    @account.entries.create!(
      name: "Unreconciled transaction",
      amount: 25,
      currency: @account.currency,
      date: Date.current,
      entryable: Transaction.new
    )

    assert_equal :needs_attention, Account::ReconciliationIndicator.for_accounts([ @account ])[@account.id]
  end

  test "has no indicator without statements or transactions" do
    account = families(:empty).accounts.create!(
      name: "Empty account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    assert_nil Account::ReconciliationIndicator.for_accounts([ account ])[account.id]
  end
end
