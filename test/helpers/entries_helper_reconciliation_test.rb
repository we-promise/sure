require "test_helper"

class EntriesHelperReconciliationTest < ActionView::TestCase
  include EntriesHelper

  test "statement label prefers period dates when present" do
    statement = AccountStatement.new(
      filename: "jan.pdf",
      period_start_on: Date.new(2026, 1, 1),
      period_end_on: Date.new(2026, 1, 31)
    )

    assert_equal "#{I18n.l(statement.period_start_on)} – #{I18n.l(statement.period_end_on)}",
                 entry_reconciliation_statement_label(statement)
  end

  test "statement label falls back to filename without period" do
    statement = AccountStatement.new(filename: "orphan.pdf")

    assert_equal "orphan.pdf", entry_reconciliation_statement_label(statement)
  end

  test "pill tone and icon map by state" do
    assert_equal :success, entry_reconciliation_pill_tone(:reconciled)
    assert_equal :info, entry_reconciliation_pill_tone(:cleared)
    assert_equal :neutral, entry_reconciliation_pill_tone(:uncleared)

    assert_equal "circle-check", entry_reconciliation_icon(:reconciled)
    assert_equal "check", entry_reconciliation_icon(:cleared)
    assert_equal "circle", entry_reconciliation_icon(:uncleared)
  end
end
