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

  # ChangeInPositionValues covers the listed positions only, so a statement
  # that also holds crypto or spot metals totals short of IBKR's own NAV.
  test "reads the current balance from the latest NAV row" do
    parsed = IbkrItem::ReportParser.new(nav_statement_xml).parse
    account = parsed[:accounts].first

    assert_equal BigDecimal("1500.00"), account[:current_balance]
    assert_equal BigDecimal("200.00"), account[:cash_balance]
  end

  # The balance is anchored on the statement's report date, so the figure has
  # to be the NAV of that date rather than of whichever row is newest.
  test "prefers the NAV row dated with the statement's report date" do
    xml = nav_statement_xml(open_positions: open_positions_on("2026-05-07"))

    account = IbkrItem::ReportParser.new(xml).parse[:accounts].first

    assert_equal Date.new(2026, 5, 7), account[:report_date]
    assert_equal BigDecimal("1400.00"), account[:current_balance]
  end

  test "falls back to position values plus cash when the statement carries no NAV" do
    xml = nav_statement_xml.sub(%r{<EquitySummaryInBase>.*</EquitySummaryInBase>}m, "")

    account = IbkrItem::ReportParser.new(xml).parse[:accounts].first

    assert_equal BigDecimal("1000.00"), account[:current_balance]
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

  private

    # Positions (800) plus cash (200) come to 1000; the NAV says 1500, the
    # difference being whatever the statement holds outside ChangeInPositionValues.
    # The BASE_SUMMARY row shares the latest date, so it would be picked if it
    # were not skipped.
    def nav_statement_xml(open_positions: "")
      <<~XML
        <FlexQueryResponse queryName="Sure Test">
          <FlexStatement accountId="U1234567" fromDate="2026-05-07" toDate="2026-05-08">
            <AccountInformation accountId="U1234567" currency="USD" />
            <ChangeInPositionValues>
              <ChangeInPositionValue accountId="U1234567" currency="BASE_SUMMARY" endOfPeriodValue="800.00" />
            </ChangeInPositionValues>
            <CashReport>
              <CashReportCurrency currency="BASE_SUMMARY" endingCash="200.00" />
            </CashReport>
            #{open_positions}
            <EquitySummaryInBase>
              <EquitySummaryByReportDateInBase currency="USD" reportDate="2026-05-07" total="1400.00" />
              <EquitySummaryByReportDateInBase currency="USD" reportDate="2026-05-08" total="1500.00" />
              <EquitySummaryByReportDateInBase currency="BASE_SUMMARY" reportDate="2026-05-08" total="9999.00" />
            </EquitySummaryInBase>
          </FlexStatement>
        </FlexQueryResponse>
      XML
    end

    # report_date follows the open positions when the statement has any, so a
    # date of their own is what puts it out of step with the latest NAV row.
    def open_positions_on(date)
      <<~XML
        <OpenPositions>
          <OpenPosition assetCategory="STK" conid="265598" securityID="US0378331005" securityIDType="ISIN" symbol="AAPL" position="10" markPrice="150.00" currency="USD" fxRateToBase="1" costBasisPrice="125.50" reportDate="#{date}" side="Long" />
        </OpenPositions>
      XML
    end
end
