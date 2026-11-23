require "test_helper"

class ReconcileAccountTransferKindsJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @term_deposit = @family.accounts.create!(
      name: "Term deposit", balance: 0, currency: "USD",
      accountable: Depository.new(subtype: "cd"), available_on: 1.year.from_now.to_date
    )
  end

  test "changing an account's availability queues the job" do
    assert_enqueued_with(job: ReconcileAccountTransferKindsJob, args: [ @term_deposit ]) do
      @term_deposit.update!(liquidity_choice: "immediate")
    end
  end

  test "renaming an account does not queue the job" do
    assert_no_enqueued_jobs(only: ReconcileAccountTransferKindsJob) do
      @term_deposit.update!(name: "Renamed deposit")
    end
  end

  test "a transfer into an account marked available is no longer saving" do
    category = ensure_investment_contributions_category(@family)
    transfer = create_transfer(from: accounts(:depository), to: @term_deposit)
    transfer.outflow_transaction.update_columns(kind: "investment_contribution", category_id: category.id)

    perform_enqueued_jobs(only: ReconcileAccountTransferKindsJob) do
      @term_deposit.update!(liquidity_choice: "immediate")
    end

    outflow = transfer.outflow_transaction.reload
    assert_equal "funds_movement", outflow.kind
    assert_nil outflow.category_id
  end

  test "a transfer into an account marked locked becomes saving" do
    savings = @family.accounts.create!(name: "Savings", balance: 0, currency: "USD", accountable: Depository.new(subtype: "savings"))
    transfer = create_transfer(from: accounts(:depository), to: savings)

    perform_enqueued_jobs(only: ReconcileAccountTransferKindsJob) do
      savings.update!(liquidity_choice: "long_term")
    end

    assert_equal "investment_contribution", transfer.outflow_transaction.reload.kind
  end

  private
    def create_transfer(from:, to:, amount: 100)
      inflow = to.entries.create!(
        name: "Transfer in", amount: -amount, date: Date.current, currency: "USD",
        entryable: Transaction.new(kind: "funds_movement")
      )
      outflow = from.entries.create!(
        name: "Transfer out", amount: amount, date: Date.current, currency: "USD",
        entryable: Transaction.new(kind: "funds_movement")
      )
      Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction, status: "confirmed")
    end
end
