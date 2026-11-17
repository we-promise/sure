require "test_helper"

class Transfer::SavingsKindReconcilerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @term_deposit = @family.accounts.create!(
      name: "Term deposit", balance: 0, currency: "USD",
      accountable: Depository.new(subtype: "cd"), available_on: 1.year.from_now.to_date
    )
  end

  test "reclassifies an older transfer into a locked deposit as saving" do
    transfer = create_transfer(from: accounts(:depository), to: @term_deposit, outflow_kind: "funds_movement")

    result = Transfer::SavingsKindReconciler.new.run

    assert_equal "investment_contribution", transfer.outflow_transaction.reload.kind
    assert_equal "funds_movement", transfer.inflow_transaction.reload.kind
    assert_equal({ "funds_movement->investment_contribution" => 1 }, result.changed)
  end

  test "leaves a transfer booked after the release date alone" do
    @term_deposit.update!(available_on: 1.month.ago.to_date)
    transfer = create_transfer(from: accounts(:depository), to: @term_deposit, outflow_kind: "funds_movement")

    assert_empty Transfer::SavingsKindReconciler.new.run.changed
    assert_equal "funds_movement", transfer.outflow_transaction.reload.kind
  end

  test "leaves transfers into instant-access accounts alone" do
    savings = @family.accounts.create!(name: "Savings", balance: 0, currency: "USD", accountable: Depository.new(subtype: "savings"))
    create_transfer(from: accounts(:depository), to: savings, outflow_kind: "funds_movement")

    assert_equal 0, Transfer::SavingsKindReconciler.new.run.checked
  end

  test "keeps kinds the user chose and locked kinds" do
    one_time = create_transfer(from: accounts(:depository), to: @term_deposit, outflow_kind: "one_time")
    locked = create_transfer(from: accounts(:depository), to: @term_deposit, outflow_kind: "funds_movement")
    locked.outflow_transaction.lock_attr!(:kind)

    Transfer::SavingsKindReconciler.new.run

    assert_equal "one_time", one_time.outflow_transaction.reload.kind
    assert_equal "funds_movement", locked.outflow_transaction.reload.kind
  end

  test "dry run reports without writing and a real run is idempotent" do
    transfer = create_transfer(from: accounts(:depository), to: @term_deposit, outflow_kind: "funds_movement")

    assert_equal({ "funds_movement->investment_contribution" => 1 }, Transfer::SavingsKindReconciler.new(dry_run: true).run.changed)
    assert_equal "funds_movement", transfer.outflow_transaction.reload.kind

    Transfer::SavingsKindReconciler.new.run
    assert_empty Transfer::SavingsKindReconciler.new.run.changed
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
