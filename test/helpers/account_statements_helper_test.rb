require "test_helper"

class AccountStatementsHelperTest < ActionView::TestCase
  test "reconciliation label falls back for invalid checks" do
    opening_balance = I18n.t("account_statements.reconciliation.checks.opening_balance")
    closing_balance = I18n.t("account_statements.reconciliation.checks.closing_balance")
    unknown_check = I18n.t("account_statements.reconciliation.checks.unknown_check")

    assert_equal opening_balance, account_statement_reconciliation_label({ key: "opening_balance" })
    assert_equal closing_balance, account_statement_reconciliation_label({ "key" => "closing_balance" })
    assert_equal unknown_check, account_statement_reconciliation_label({})
    assert_equal unknown_check, account_statement_reconciliation_label(nil)
    assert_equal unknown_check, account_statement_reconciliation_label([])
  end
end
