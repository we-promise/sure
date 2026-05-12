require "test_helper"

class AccountStatementsHelperTest < ActionView::TestCase
  test "reconciliation label falls back for invalid checks" do
    assert_equal "Opening balance", account_statement_reconciliation_label({ key: "opening_balance" })
    assert_equal "Closing balance", account_statement_reconciliation_label({ "key" => "closing_balance" })
    assert_equal "Unknown check", account_statement_reconciliation_label({})
    assert_equal "Unknown check", account_statement_reconciliation_label(nil)
    assert_equal "Unknown check", account_statement_reconciliation_label([])
  end
end
