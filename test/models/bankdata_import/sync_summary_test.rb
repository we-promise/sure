# frozen_string_literal: true

require "test_helper"

class BankdataImport::SyncSummaryTest < ActiveSupport::TestCase
  test "aggregates statuses side totals and items" do
    summary = BankdataImport::SyncSummary.new([
      { status: "created", amount: "100.91", income_expense: "Expense", source_transaction_id: "1", external_id: "a", category_name: "Boodschappen" },
      { status: "already_imported", amount: "5.00", income_expense: "Income", source_transaction_id: "2", external_id: "b" },
      { status: "uncategorized", amount: "3.50", income_expense: "Expense", source_transaction_id: "3", external_id: "c" },
      { status: "invalid", source_transaction_id: "4", external_id: "d", reason: "bad amount" },
      { status: "failed", source_transaction_id: "5", external_id: "e", reason: "boom" },
      { status: "skipped", source_transaction_id: "6", external_id: "f", reason: "not ready" }
    ])

    assert_equal 6, summary.total
    assert_equal 1, summary.created
    assert_equal 1, summary.already_imported
    assert_equal 1, summary.uncategorized
    assert_equal 1, summary.invalid
    assert_equal 1, summary.failed
    assert_equal 1, summary.skipped
    assert_equal "104.41", summary.expense_total
    assert_equal "5.00", summary.income_total
    assert_equal "boom", summary.items.fifth[:reason]
  end

  test "counts uncategorized created rows" do
    summary = BankdataImport::SyncSummary.new([
      { status: "created", amount: "5.95", income_expense: "Expense", category_name: nil },
      { status: "uncategorized", amount: "10.00", income_expense: "Expense" }
    ])

    assert_equal 2, summary.total
    assert_equal 1, summary.created
    assert_equal 2, summary.uncategorized
  end
end
