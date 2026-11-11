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
    assert_equal 2, first_account[:equity_summary_in_base].size
    assert_equal 1, first_account[:open_positions].size
    assert_equal 2, first_account[:trades].size
    assert_equal 2, first_account[:cash_transactions].size

    second_account = parsed[:accounts].second
    assert_equal "U7654321", second_account[:ibkr_account_id]
    assert_equal BigDecimal("250"), second_account[:cash_balance]
    assert_equal BigDecimal("250"), second_account[:current_balance]
    assert_equal 1, second_account[:equity_summary_in_base].size
  end

  test "sums position values across asset categories instead of reading a single row" do
    xml = <<~XML
      <FlexQueryResponse queryName="Sure Test" type="AF">
        <FlexStatements count="1">
          <FlexStatement accountId="U1234567" fromDate="2026-05-01" toDate="2026-05-08" whenGenerated="2026-05-08;12:00:00">
            <AccountInformation accountId="U1234567" currency="USD" />
            <ChangeInPositionValues>
              <ChangeInPositionValue accountId="U1234567" currency="BASE_SUMMARY" assetCategory="WAR" endOfPeriodValue="0.00" />
              <ChangeInPositionValue accountId="U1234567" currency="BASE_SUMMARY" assetCategory="STK" endOfPeriodValue="50000.00" />
              <ChangeInPositionValue accountId="U1234567" currency="BASE_SUMMARY" assetCategory="OPT" endOfPeriodValue="2500.00" />
              <ChangeInPositionValue accountId="U1234567" currency="USD" assetCategory="WAR" endOfPeriodValue="0.00" />
              <ChangeInPositionValue accountId="U1234567" currency="USD" assetCategory="STK" endOfPeriodValue="50000.00" />
              <ChangeInPositionValue accountId="U1234567" currency="USD" assetCategory="OPT" endOfPeriodValue="2500.00" />
            </ChangeInPositionValues>
            <CashReport>
              <CashReportCurrency currency="BASE_SUMMARY" endingCash="10000.00" />
              <CashReportCurrency currency="USD" endingCash="10000.00" />
            </CashReport>
          </FlexStatement>
        </FlexStatements>
      </FlexQueryResponse>
    XML

    account = IbkrItem::ReportParser.new(xml).parse[:accounts].first

    assert_equal BigDecimal("52500.00"), account[:current_balance] - account[:cash_balance]
    assert_equal BigDecimal("62500.00"), account[:current_balance]
  end

  test "raises parse error for malformed xml" do
    error = assert_raises(IbkrItem::ReportParser::ParseError) do
      IbkrItem::ReportParser.new("<FlexQueryResponse><FlexStatement>").parse
    end

    assert_match "Invalid IBKR Flex XML", error.message
  end

  test "raises parse error when flex statements are missing" do
    error = assert_raises(IbkrItem::ReportParser::ParseError) do
      IbkrItem::ReportParser.new('<FlexQueryResponse queryName="Sure Test" />').parse
    end

    assert_equal "Invalid IBKR Flex XML: no FlexStatement nodes found.", error.message
  end

  test "raises parse error when flex statement account id is missing" do
    xml = <<~XML
      <FlexQueryResponse queryName="Sure Test">
        <FlexStatement>
          <AccountInformation currency="CHF" />
        </FlexStatement>
      </FlexQueryResponse>
    XML

    error = assert_raises(IbkrItem::ReportParser::ParseError) do
      IbkrItem::ReportParser.new(xml).parse
    end

    assert_equal "Invalid IBKR Flex XML: missing account identifier in FlexStatement.", error.message
  end
end
