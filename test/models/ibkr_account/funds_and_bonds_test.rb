require "test_helper"

# A statement holding a stock, a mutual fund, a bond, a long option and a short
# stock (test/fixtures/files/ibkr/flex_statement_funds_bonds.xml), run through
# the parser and the processor the way a sync runs it.
class IbkrAccount::FundsAndBondsTest < ActiveSupport::TestCase
  fixtures :families, :ibkr_items, :ibkr_accounts, :accounts, :securities

  setup do
    @family = families(:dylan_family)
    @ibkr_account = ibkr_accounts(:main_account)
    @account = @family.accounts.create!(
      name: "IBKR Investment",
      balance: 0,
      cash_balance: 0,
      currency: "EUR",
      accountable: Investment.new(subtype: "brokerage")
    )
    @ibkr_account.ensure_account_provider!(@account)

    @statement = IbkrItem::ReportParser.new(file_fixture("ibkr/flex_statement_funds_bonds.xml").read).parse[:accounts].first
    @report_date = Date.new(2026, 5, 8)
  end

  test "the current balance sums every asset category's position value" do
    # 9850 bond + 2500 fund + 300 option + 1500 stock, plus 1000 cash: IBKR's NAV.
    assert_equal BigDecimal("15150.00"), @statement[:current_balance]
  end

  test "a position value row with no category is taken as the total" do
    rows = [
      { "currency" => "BASE_SUMMARY", "asset_category" => "STK", "end_of_period_value" => "1500" },
      { "currency" => "BASE_SUMMARY", "asset_category" => "", "end_of_period_value" => "1800" },
      { "currency" => "BASE_SUMMARY", "asset_category" => "BOND", "end_of_period_value" => "300" }
    ]

    assert_equal BigDecimal("1800"), IbkrItem::ReportParser.new("<x/>").send(:extract_current_balance, rows, "EUR")
  end

  test "fund and bond positions are imported at IBKR's value and cost" do
    process!

    fund = holding_for("SURFUND")
    assert_equal BigDecimal("12.5"), fund.qty
    assert_equal BigDecimal("200"), fund.price
    assert_equal BigDecimal("2500"), fund.amount
    assert_equal BigDecimal("180"), fund.cost_basis

    # 10,000 face at 98.50% of par, counted in units of 100 face.
    bond = holding_for("BOND:SURCO 3 1/2 06/15/30")
    assert_equal BigDecimal("100"), bond.qty
    assert_equal BigDecimal("98.5"), bond.price
    assert_equal BigDecimal("9850"), bond.amount
    assert_equal BigDecimal("97.25"), bond.cost_basis
    assert_equal BigDecimal("9725"), bond.qty * bond.cost_basis

    stock = holding_for("SURETST")
    assert_equal BigDecimal("2000"), stock.amount
  end

  test "imported holdings and the skipped positions add up to the balance" do
    process!

    @account.reload
    assert_equal BigDecimal("15150"), @account.balance
    assert_equal 3, @account.holdings.where(date: @report_date).count

    holdings_value = @account.holdings.where(date: @report_date).sum(:amount)
    assert_equal BigDecimal("14350"), holdings_value

    # What is left of the balance is IBKR's cash plus the skipped long call
    # (+300) and short stock (-500).
    assert_equal BigDecimal("1000") + 300 - 500, @account.balance - holdings_value
  end

  test "a bond is its own offline security, not a listed one sharing its symbol" do
    listed = Security.create!(ticker: "SURCO 3 1/2 06/15/30", name: "Listed lookalike")

    process!

    bond = Security.find_by!(ticker: "BOND:SURCO 3 1/2 06/15/30")
    assert_not_equal listed, bond
    assert bond.offline?
    assert_equal "ibkr_bond", bond.offline_reason
    assert_equal "SURCO 3 1/2 06/15/30", bond.name
    assert_empty @account.holdings.where(security: listed)
  end

  test "a bond without the multiplier field is counted per 100 face" do
    @statement[:open_positions].each { |row| row.delete("multiplier") }
    @statement[:trades].each { |row| row.delete("multiplier") }

    process!

    bond = holding_for("BOND:SURCO 3 1/2 06/15/30")
    assert_equal BigDecimal("100"), bond.qty
    assert_equal BigDecimal("9850"), bond.amount

    trade = @account.entries.find_by!(external_id: "ibkr_trade_9102").entryable
    assert_equal BigDecimal("100"), trade.qty
  end

  test "fund and bond trades are imported in the holdings' units" do
    process!

    fund_trade = @account.entries.find_by!(external_id: "ibkr_trade_9101")
    assert_equal BigDecimal("12.5"), fund_trade.entryable.qty
    assert_equal BigDecimal("180"), fund_trade.entryable.price
    assert_equal BigDecimal("2250"), fund_trade.amount
    assert_equal "SURFUND", fund_trade.entryable.security.ticker

    bond_trade = @account.entries.find_by!(external_id: "ibkr_trade_9102")
    assert_equal BigDecimal("100"), bond_trade.entryable.qty
    assert_equal BigDecimal("97.25"), bond_trade.entryable.price
    assert_equal BigDecimal("5"), bond_trade.entryable.fee
    # IBKR's proceeds (9725) plus the commission.
    assert_equal BigDecimal("9730"), bond_trade.amount
    assert_equal "Buy 100.0 units of BOND:SURCO 3 1/2 06/15/30", bond_trade.name
    assert_equal holding_for("BOND:SURCO 3 1/2 06/15/30").security, bond_trade.entryable.security
  end

  test "accrued interest paid on a bond lands on the bond's security" do
    process!

    entry = @account.entries.find_by!(external_id: "ibkr_cash_9201")
    assert_equal "Interest", entry.entryable.investment_activity_label
    assert_equal Security.find_by!(ticker: "BOND:SURCO 3 1/2 06/15/30").id, entry.entryable.extra["security_id"]
  end

  test "positions and trades of unsupported types are reported, one entry each" do
    assert_difference -> { DebugLogEntry.where(provider_key: "ibkr").count }, 2 do
      process!
    end

    positions = DebugLogEntry.find_by!(provider_key: "ibkr", message: "Skipped IBKR positions of unsupported types")
    assert_equal "warn", positions.level
    assert_equal @family, positions.family
    assert_equal({ "OPT" => 1, "STK Short" => 1 }, positions.metadata["skipped_position_types"])

    trades = DebugLogEntry.find_by!(provider_key: "ibkr", message: "Skipped IBKR trades of unsupported types")
    assert_equal({ "OPT" => 1 }, trades.metadata["skipped_trade_types"])

    assert_nil @account.entries.find_by(external_id: "ibkr_trade_9103")
    assert_nil Security.find_by(ticker: "SURETST 260619C00110000")
  end

  test "a statement with only supported positions and trades reports nothing" do
    @statement[:open_positions].reject! { |row| row["asset_category"] == "OPT" || row["side"] == "Short" }
    @statement[:trades].reject! { |row| row["asset_category"] == "OPT" }

    assert_no_difference -> { DebugLogEntry.where(provider_key: "ibkr").count } do
      process!
    end
  end

  private

    def process!
      @ibkr_account.upsert_from_ibkr_statement!(@statement)
      IbkrAccount::Processor.new(@ibkr_account).process
    end

    def holding_for(ticker)
      @account.holdings.joins(:security).find_by!(securities: { ticker: ticker }, date: @report_date)
    end
end
