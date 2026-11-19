require "test_helper"

class Transfer::InvestmentKindReconcilerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "repairs a legacy investment-to-investment outflow still marked as a contribution" do
    transfer = create_transfer(from: accounts(:crypto), to: accounts(:investment), outflow_kind: "investment_contribution")

    result = Transfer::InvestmentKindReconciler.new.run

    assert_equal "funds_movement", transfer.outflow_transaction.reload.kind
    assert_equal "funds_movement", transfer.inflow_transaction.reload.kind
    assert_equal({ "investment_contribution->funds_movement" => 1 }, result.changed)
  end

  test "repairs a matched brokerage inflow an earlier sync turned back into a contribution" do
    transfer = create_transfer(from: accounts(:depository), to: accounts(:investment),
                               outflow_kind: "investment_contribution", inflow_kind: "investment_contribution")

    Transfer::InvestmentKindReconciler.new.run

    assert_equal "funds_movement", transfer.inflow_transaction.reload.kind
    assert_equal "investment_contribution", transfer.outflow_transaction.reload.kind
  end

  test "repairs a legacy pair imported without a kind hint" do
    inflow = Account::ProviderImportAdapter.new(accounts(:investment)).import_transaction(
      external_id: "plaid_no_hint_in", amount: -80, currency: "USD", date: Date.current,
      name: "Deposit", source: "plaid"
    )
    outflow = Account::ProviderImportAdapter.new(accounts(:crypto)).import_transaction(
      external_id: "plaid_no_hint_out", amount: 80, currency: "USD", date: Date.current,
      name: "Withdrawal to brokerage", source: "plaid"
    )
    transfer = Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction, status: "confirmed")
    # State left by the old classification of investment-to-investment transfers.
    transfer.outflow_transaction.update_columns(kind: "investment_contribution")

    Transfer::InvestmentKindReconciler.new.run

    assert_equal "funds_movement", outflow.transaction.reload.kind
  end

  test "keeps kinds the user chose, excluded entries and locked kinds" do
    one_time = create_transfer(from: accounts(:crypto), to: accounts(:investment), outflow_kind: "one_time")
    excluded = create_transfer(from: accounts(:crypto), to: accounts(:investment), outflow_kind: "investment_contribution")
    excluded.outflow_transaction.entry.update_columns(excluded: true)
    locked = create_transfer(from: accounts(:crypto), to: accounts(:investment), outflow_kind: "investment_contribution")
    locked.outflow_transaction.lock_attr!(:kind)

    Transfer::InvestmentKindReconciler.new.run

    assert_equal "one_time", one_time.outflow_transaction.reload.kind
    assert_equal "investment_contribution", excluded.outflow_transaction.reload.kind
    assert_equal "investment_contribution", locked.outflow_transaction.reload.kind
  end

  test "leaves transfers into other account types alone" do
    loan = create_transfer(from: accounts(:depository), to: accounts(:loan),
                           outflow_kind: "loan_payment", inflow_kind: "loan_payment")

    result = Transfer::InvestmentKindReconciler.new.run

    assert_equal "loan_payment", loan.inflow_transaction.reload.kind
    assert_equal 0, result.checked
  end

  test "is idempotent and touches the entry so caches expire" do
    transfer = create_transfer(from: accounts(:crypto), to: accounts(:investment), outflow_kind: "investment_contribution")
    entry = transfer.outflow_transaction.entry
    entry.update_columns(updated_at: 1.day.ago)

    Transfer::InvestmentKindReconciler.new.run
    assert entry.reload.updated_at > 1.minute.ago

    assert_empty Transfer::InvestmentKindReconciler.new.run.changed
  end

  test "dry run reports without writing" do
    transfer = create_transfer(from: accounts(:crypto), to: accounts(:investment), outflow_kind: "investment_contribution")

    result = Transfer::InvestmentKindReconciler.new(dry_run: true).run

    assert_equal({ "investment_contribution->funds_movement" => 1 }, result.changed)
    assert_equal "investment_contribution", transfer.outflow_transaction.reload.kind
  end

  private
    def create_transfer(from:, to:, outflow_kind:, inflow_kind: "funds_movement", amount: 100)
      inflow = to.entries.create!(
        name: "Transfer in", amount: -amount, date: Date.current, currency: "USD",
        entryable: Transaction.new(kind: inflow_kind)
      )
      outflow = from.entries.create!(
        name: "Transfer out", amount: amount, date: Date.current, currency: "USD",
        entryable: Transaction.new(kind: outflow_kind)
      )
      Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction, status: "confirmed")
    end
end
