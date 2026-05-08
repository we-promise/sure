require "test_helper"

class IbkrItemReportParserTest < ActiveSupport::TestCase
  test "parses accounts, balances, and positions from flex xml" do
    parsed = IbkrItem::ReportParser.new(file_fixture("ibkr/flex_statement.xml").read).parse

    assert_equal "Sure Test", parsed[:metadata]["query_name"]
    assert_equal 2, parsed[:accounts].size

    first_account = parsed[:accounts].first
    assert_equal "U1234567", first_account[:ibkr_account_id]
    assert_equal "CHF", first_account[:currency]
    assert_equal BigDecimal("1000.50"), first_account[:cash_balance]
    assert_equal BigDecimal("3351.00"), first_account[:current_balance]
    assert_equal 1, first_account[:open_positions].size
    assert_equal 2, first_account[:trades].size
    assert_equal 2, first_account[:cash_transactions].size

    second_account = parsed[:accounts].second
    assert_equal "U7654321", second_account[:ibkr_account_id]
    assert_equal BigDecimal("250"), second_account[:cash_balance]
    assert_equal BigDecimal("250"), second_account[:current_balance]
  end
end
