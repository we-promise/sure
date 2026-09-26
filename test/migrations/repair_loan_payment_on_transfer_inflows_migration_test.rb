# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260926171500_repair_loan_payment_on_transfer_inflows")

class RepairLoanPaymentOnTransferInflowsMigrationTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @checking = @family.accounts.create!(name: "Checking", currency: "USD", balance: 5000, accountable: Depository.new)
    @loan = @family.accounts.create!(name: "Home loan", currency: "USD", balance: 300_000, accountable: Loan.new)

    @outflow = import(@checking, "out_1", 500)
    @inflow = import(@loan, "in_1", -500)
    @family.auto_match_transfers!
    # The state earlier syncs left behind: the matched inflow leg re-stamped.
    @inflow.transaction.update_columns(kind: "loan_payment")

    @unmatched_inflow = import(@loan, "in_unmatched", -700, date: 20.days.ago.to_date)
  end

  test "resets a matched loan inflow leg to funds_movement" do
    run_migration

    assert_equal "funds_movement", @inflow.transaction.reload.kind
  end

  test "leaves the outflow leg and unmatched loan inflows alone" do
    run_migration

    assert_equal "loan_payment", @outflow.transaction.reload.kind
    assert_equal "loan_payment", @unmatched_inflow.transaction.reload.kind
  end

  # IncomeStatement#totals with no transactions_scope covers every date, so both
  # repayments count: the matched pair (500) and the unmatched one (700).
  test "counts a repaired pair once in the income statement" do
    assert_equal 1700, income_statement_totals.expense_money.amount.to_i, "the stamped inflow leg counts the pair twice"

    run_migration

    assert_equal 1200, income_statement_totals.expense_money.amount.to_i
    assert_equal 0, income_statement_totals.income_money.amount.to_i
  end

  test "can be run again" do
    2.times { run_migration }

    assert_equal "funds_movement", @inflow.transaction.reload.kind
  end

  private

    def import(account, id, amount, date: Date.current)
      Account::ProviderImportAdapter.new(account).import_transaction(
        external_id: id, amount: amount, currency: "USD", date: date,
        name: "Loan repayment", source: "simplefin"
      )
    end

    def income_statement_totals
      IncomeStatement.new(@family).totals(date_range: 30.days.ago.to_date..Date.current)
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        RepairLoanPaymentOnTransferInflows.new.up
      end
    end
end
