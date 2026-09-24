require "test_helper"

class Rule::ConditionFilter::TransactionTypeTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @rule = rules(:one)
    @filter = Rule::ConditionFilter::TransactionType.new(@rule)
    @family = @rule.family
    @account = @family.accounts.first
    @other_account = @family.accounts.where.not(id: @account.id).first
  end

  test "excludes both legs of a still-pending auto-matched transfer from income and expense" do
    outflow_txn = create_transaction(account: @account, amount: 190, kind: "standard").transaction
    inflow_txn = create_transaction(account: @other_account, amount: -190, kind: "standard").transaction
    Transfer.create!(inflow_transaction: inflow_txn, outflow_transaction: outflow_txn)

    real_expense = create_transaction(account: @account, amount: 50, kind: "standard").transaction
    real_income = create_transaction(account: @account, amount: -30, kind: "standard").transaction

    scope = @filter.prepare(Transaction.where(id: [ outflow_txn.id, inflow_txn.id, real_expense.id, real_income.id ]))

    expense_result = @filter.apply(scope, "=", "expense")
    income_result = @filter.apply(scope, "=", "income")

    assert_equal [ real_expense.id ], expense_result.pluck("transactions.id")
    assert_equal [ real_income.id ], income_result.pluck("transactions.id")
  end

  test "includes both legs of a still-pending auto-matched transfer in the transfer bucket" do
    outflow_txn = create_transaction(account: @account, amount: 190, kind: "standard").transaction
    inflow_txn = create_transaction(account: @other_account, amount: -190, kind: "standard").transaction
    Transfer.create!(inflow_transaction: inflow_txn, outflow_transaction: outflow_txn)

    unrelated = create_transaction(account: @account, amount: 10, kind: "standard").transaction

    scope = @filter.prepare(Transaction.where(id: [ outflow_txn.id, inflow_txn.id, unrelated.id ]))
    transfer_result = @filter.apply(scope, "=", "transfer")

    assert_equal [ outflow_txn.id, inflow_txn.id ].sort, transfer_result.pluck("transactions.id").sort
  end

  test "still includes confirmed transfer-kind transactions in the transfer bucket" do
    confirmed = create_transaction(account: @account, amount: 100, kind: "funds_movement").transaction

    scope = @filter.prepare(Transaction.where(id: confirmed.id))
    transfer_result = @filter.apply(scope, "=", "transfer")

    assert_equal [ confirmed.id ], transfer_result.pluck("transactions.id")
  end
end
