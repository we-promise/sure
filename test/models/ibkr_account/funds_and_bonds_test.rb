require "test_helper"

# A statement holding a stock, a mutual fund, a bond, a long option and a short
# stock (test/fixtures/files/ibkr/flex_statement_funds_bonds.xml), run through
# the parser and the processor the way a sync runs it.
class IbkrAccount::FundsAndBondsTest < ActiveSupport::TestCase
  BOND_TICKER = "BOND:SURCO 3 1/2 06/15/30:900003".freeze

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
    bond = holding_for("BOND:SURCO 3 1/2 06/15/30:900003")
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

    bond = Security.find_by!(ticker: "BOND:SURCO 3 1/2 06/15/30:900003")
    assert_not_equal listed, bond
    assert bond.offline?
    assert_equal "ibkr_bond", bond.offline_reason
    assert_equal "SURCO 3 1/2 06/15/30", bond.name
    assert_empty @account.holdings.where(security: listed)
  end

  test "two bonds sharing a symbol are kept apart by their contract id" do
    bond_position = @statement[:open_positions].find { |row| row["conid"] == "900003" }
    @statement[:open_positions] << bond_position.merge(
      "conid" => "900007", "security_id" => "XX0000000052", "position" => "5000",
      "mark_price" => "101.00", "position_value" => "5050.00",
      "cost_basis_price" => "99.00", "cost_basis_money" => "4950.00"
    )
    bond_trade = @statement[:trades].find { |row| row["conid"] == "900003" }
    @statement[:trades] << bond_trade.merge(
      "trade_id" => "9105", "transaction_id" => "9105a", "conid" => "900007",
      "quantity" => "5000", "trade_price" => "99.00", "proceeds" => "-4950.00"
    )
    @statement[:cash_transactions] << @statement[:cash_transactions].first.merge(
      "transaction_id" => "9202", "amount" => "-7.00", "conid" => "900007"
    )

    process!

    bonds = @account.holdings.joins(:security).where(date: @report_date, securities: { offline_reason: "ibkr_bond" })
    assert_equal [ BigDecimal("5050"), BigDecimal("9850") ], bonds.map(&:amount).sort

    first = holding_for("BOND:SURCO 3 1/2 06/15/30:900003")
    assert_equal BigDecimal("100"), first.qty
    assert_equal BigDecimal("9850"), first.amount
    assert_equal BigDecimal("97.25"), first.cost_basis

    second = holding_for("BOND:SURCO 3 1/2 06/15/30:900007")
    assert_equal BigDecimal("50"), second.qty
    assert_equal BigDecimal("5050"), second.amount
    assert_equal BigDecimal("99"), second.cost_basis
    assert_not_equal first.security, second.security

    assert_equal first.security, @account.entries.find_by!(external_id: "ibkr_trade_9102").entryable.security
    assert_equal second.security, @account.entries.find_by!(external_id: "ibkr_trade_9105").entryable.security
    assert_equal first.security.id, @account.entries.find_by!(external_id: "ibkr_cash_9201").entryable.extra["security_id"]
    assert_equal second.security.id, @account.entries.find_by!(external_id: "ibkr_cash_9202").entryable.extra["security_id"]
  end

  test "a bond without the multiplier field is counted per 100 face" do
    @statement[:open_positions].each { |row| row.delete("multiplier") }
    @statement[:trades].each { |row| row.delete("multiplier") }

    process!

    bond = holding_for("BOND:SURCO 3 1/2 06/15/30:900003")
    assert_equal BigDecimal("100"), bond.qty
    assert_equal BigDecimal("9850"), bond.amount

    trade = @account.entries.find_by!(external_id: "ibkr_trade_9102").entryable
    assert_equal BigDecimal("100"), trade.qty
  end

  test "a bond reported with multiplier 1 is still counted per 100 face" do
    bond_rows(@statement).each { |row| row["multiplier"] = "1" }

    process!

    bond = holding_for("BOND:SURCO 3 1/2 06/15/30:900003")
    assert_equal BigDecimal("100"), bond.qty
    assert_equal BigDecimal("98.5"), bond.price
    assert_equal BigDecimal("9850"), bond.amount
    assert_equal BigDecimal("9725"), bond.qty * bond.cost_basis
  end

  test "a bond reported with multiplier 0.01 is counted per 100 face" do
    bond_rows(@statement).each { |row| row["multiplier"] = "0.01" }

    process!

    bond = holding_for("BOND:SURCO 3 1/2 06/15/30:900003")
    assert_equal BigDecimal("100"), bond.qty
    assert_equal BigDecimal("9850"), bond.amount
  end

  test "a bond price quoted per unit, not per 100 face, is counted per unit" do
    # positionValue = position x markPrice, so the face value is the quantity.
    per_unit_position!

    process!

    bond = holding_for(BOND_TICKER)
    assert_equal BigDecimal("10000"), bond.qty
    assert_equal BigDecimal("9850"), bond.amount
  end

  # One bond security has one unit. The position says 10,000 units at 0.985; the
  # trade, whose value says 100 face at 97.25, is carried into that unit: the
  # same 9,725 bought, as 10,000 units at 0.9725.
  test "a bond's trade follows the unit its open position implies" do
    per_unit_position!

    process!

    trade = @account.entries.find_by!(external_id: "ibkr_trade_9102")
    assert_equal BigDecimal("10000"), trade.entryable.qty
    assert_equal BigDecimal("0.9725"), trade.entryable.price
    assert_equal BigDecimal("9730"), trade.amount

    entry = holding_for(BOND_TICKER)
    assert_equal BigDecimal("0.9725"), entry.cost_basis
  end

  test "a bond's position follows the unit it implies when its trade is quoted per unit" do
    # The position says 100 units at 98.50 (the fixture); this trade says
    # 10,000 face at 0.9725 a unit, so it is 100 units at 97.25 in the position's.
    trade = @statement[:trades].find { |row| row["asset_category"] == "BOND" }
    trade.merge!("multiplier" => "1", "trade_price" => "0.9725")

    process!

    entry = @account.entries.find_by!(external_id: "ibkr_trade_9102")
    assert_equal BigDecimal("100"), entry.entryable.qty
    assert_equal BigDecimal("97.25"), entry.entryable.price
    assert_equal BigDecimal("100"), holding_for(BOND_TICKER).qty
  end

  test "a position and a trade of one bond that disagree on the unit reverse to nothing before the purchase" do
    per_unit_position!

    process!
    materialize!

    bond = Security.find_by!(ticker: BOND_TICKER)
    assert_no_units_before_the_purchase(bond)

    on_trade_day = @account.holdings.find_by!(security: bond, date: Date.new(2026, 4, 2))
    assert_equal BigDecimal("10000"), on_trade_day.qty
    # The trade's price is the day's price; units x price is what was paid.
    assert_equal BigDecimal("9725"), on_trade_day.amount

    today = @account.holdings.where(security: bond).order(:date).last
    assert_equal BigDecimal("10000"), today.qty
  end

  test "a bond's holding history stays in one unit when the position is per 100 face and the trade per unit" do
    trade = @statement[:trades].find { |row| row["asset_category"] == "BOND" }
    trade.merge!("multiplier" => "1", "trade_price" => "0.9725")

    process!
    materialize!

    bond = Security.find_by!(ticker: BOND_TICKER)
    assert_no_units_before_the_purchase(bond)
    on_trade_day = @account.holdings.find_by!(security: bond, date: Date.new(2026, 4, 2))
    assert_equal BigDecimal("100"), on_trade_day.qty
    assert_equal BigDecimal("9725"), on_trade_day.amount
  end

  test "rows of one bond that disagree on the unit are reported" do
    per_unit_position!

    process!

    entry = DebugLogEntry.find_by!(provider_key: "ibkr", message: "IBKR bond trades counted in another unit than the bond's other rows")
    assert_equal "warn", entry.level
    bond = entry.metadata["bonds"].sole
    assert_equal BOND_TICKER, bond["ticker"]
    assert_equal "1.0", bond["unit_factor"]
    assert_equal [ "0.01" ], bond["row_unit_factors"]
    assert_nil DebugLogEntry.find_by(provider_key: "ibkr", message: "IBKR bond positions counted in another unit than the bond's other rows")
  end

  test "rows of one bond that agree on the unit report nothing" do
    assert_no_difference -> { DebugLogEntry.where(provider_key: "ibkr", message: [ "IBKR bond trades counted in another unit than the bond's other rows", "IBKR bond positions counted in another unit than the bond's other rows" ]).count } do
      process!
    end
  end

  test "two lots of one bond that disagree on the unit are carried into one, at 0.01 on a tie" do
    # 10,000 face at 98.50 per 100 face (the fixture), plus 5,000 at 1.01 a unit.
    lot = @statement[:open_positions].find { |row| row["asset_category"] == "BOND" }
    @statement[:open_positions] << lot.merge(
      "position" => "5000", "multiplier" => "1", "mark_price" => "1.01", "position_value" => "5050.00",
      "cost_basis_price" => "0.99", "cost_basis_money" => "4950.00"
    )

    process!

    bond = holding_for(BOND_TICKER)
    assert_equal BigDecimal("150"), bond.qty
    assert_equal BigDecimal("14900"), bond.amount
    assert_in_delta 14675, bond.qty * bond.cost_basis, 0.01

    entry = DebugLogEntry.find_by!(provider_key: "ibkr", message: "IBKR bond positions counted in another unit than the bond's other rows")
    assert_equal [ "1.0" ], entry.metadata["bonds"].sole["row_unit_factors"]
    assert_equal "0.01", entry.metadata["bonds"].sole["unit_factor"]
  end

  test "a short bond position, which is not imported, does not decide the unit" do
    short = @statement[:open_positions].find { |row| row["asset_category"] == "BOND" }
    @statement[:open_positions].delete(short)
    @statement[:open_positions] << short.merge(
      "side" => "Short", "position" => "-10000", "multiplier" => "1", "mark_price" => "0.985", "position_value" => "-9850.00"
    )

    process!

    assert_equal BigDecimal("100"), @account.entries.find_by!(external_id: "ibkr_trade_9102").entryable.qty
    assert_equal BigDecimal("97.25"), @account.entries.find_by!(external_id: "ibkr_trade_9102").entryable.price
  end

  test "a bond sold since has no position and counts in the unit its trades imply" do
    @statement[:open_positions].reject! { |row| row["asset_category"] == "BOND" }
    @statement[:trades].find { |row| row["asset_category"] == "BOND" }.merge!("multiplier" => "1")
    @statement[:trades] << @statement[:trades].find { |row| row["asset_category"] == "BOND" }.merge(
      "trade_id" => "9106", "transaction_id" => "9106a", "buy_sell" => "SELL", "quantity" => "-10000",
      "trade_price" => "98.00", "proceeds" => "9800.00", "trade_date" => "2026-04-20", "ib_commission" => "0"
    )

    process!

    buy = @account.entries.find_by!(external_id: "ibkr_trade_9102").entryable
    sell = @account.entries.find_by!(external_id: "ibkr_trade_9106").entryable
    assert_equal [ BigDecimal("100"), BigDecimal("-100") ], [ buy.qty, sell.qty ]
    assert_equal [ BigDecimal("97.25"), BigDecimal("98") ], [ buy.price, sell.price ]
  end

  test "a bond with trades that disagree on the unit and no position counts in the unit most of them imply" do
    @statement[:open_positions].reject! { |row| row["asset_category"] == "BOND" }
    template = @statement[:trades].find { |row| row["asset_category"] == "BOND" }
    # Two trades per 100 face (the fixture's and the next), one per unit.
    @statement[:trades] << template.merge("trade_id" => "9106", "transaction_id" => "9106a", "trade_date" => "2026-04-03")
    @statement[:trades] << template.merge(
      "trade_id" => "9107", "transaction_id" => "9107a", "multiplier" => "1", "trade_date" => "2026-04-04",
      "trade_price" => "0.9725"
    )

    process!

    %w[9102 9106 9107].each do |id|
      trade = @account.entries.find_by!(external_id: "ibkr_trade_#{id}").entryable
      assert_equal BigDecimal("100"), trade.qty, "trade #{id}"
      assert_equal BigDecimal("97.25"), trade.price, "trade #{id}"
    end
  end

  test "a bond trade reported with multiplier 1 is counted per 100 face" do
    bond_rows(@statement).each { |row| row["multiplier"] = "1" }

    process!

    trade = @account.entries.find_by!(external_id: "ibkr_trade_9102")
    assert_equal BigDecimal("100"), trade.entryable.qty
    assert_equal BigDecimal("97.25"), trade.entryable.price
    assert_equal BigDecimal("9730"), trade.amount
  end

  test "a bond trade without proceeds is checked against its trade money" do
    trade = @statement[:trades].find { |row| row["asset_category"] == "BOND" }
    trade.merge!("multiplier" => "1", "trade_money" => "9725.00")
    trade.delete("proceeds")

    process!

    assert_equal BigDecimal("100"), @account.entries.find_by!(external_id: "ibkr_trade_9102").entryable.qty
  end

  test "a bond row with nothing to check the unit against falls back to 100 face" do
    bond_rows(@statement).each do |row|
      row["multiplier"] = "1"
      row.delete("position_value")
      row.delete("proceeds")
    end

    process!

    assert_equal BigDecimal("100"), holding_for("BOND:SURCO 3 1/2 06/15/30:900003").qty
    assert_equal BigDecimal("100"), @account.entries.find_by!(external_id: "ibkr_trade_9102").entryable.qty
  end

  test "a multiplier on a fund or stock changes nothing" do
    @statement[:open_positions].each { |row| row["multiplier"] = "0.01" if %w[STK FUND].include?(row["asset_category"]) }
    @statement[:trades].each { |row| row["multiplier"] = "0.01" if row["asset_category"] == "FUND" }

    process!

    assert_equal BigDecimal("12.5"), holding_for("SURFUND").qty
    assert_equal BigDecimal("20"), holding_for("SURETST").qty
    assert_equal BigDecimal("12.5"), @account.entries.find_by!(external_id: "ibkr_trade_9101").entryable.qty
  end

  test "bond, fund, stock and commodity in one account each keep their own unit" do
    @statement[:open_positions] << {
      "asset_category" => "CMDTY", "conid" => "900006", "security_id" => "", "security_id_type" => "",
      "symbol" => "SURMETAL", "description" => "SURE TEST METAL", "position" => "3", "multiplier" => "0.01",
      "mark_price" => "50.00", "position_value" => "150.00", "currency" => "EUR", "fx_rate_to_base" => "1",
      "cost_basis_price" => "40.00", "report_date" => "2026-05-08", "side" => "Long"
    }
    bond_rows(@statement).each { |row| row["multiplier"] = "1" }

    process!

    assert_equal BigDecimal("100"), holding_for("BOND:SURCO 3 1/2 06/15/30:900003").qty
    assert_equal BigDecimal("12.5"), holding_for("SURFUND").qty
    assert_equal BigDecimal("20"), holding_for("SURETST").qty
    assert_equal BigDecimal("3"), holding_for("CMDTY:SURMETAL").qty
    assert_equal BigDecimal("150"), holding_for("CMDTY:SURMETAL").amount
  end

  test "a lowercase category is treated like its upper-case form" do
    @statement[:open_positions] << {
      "asset_category" => "cmdty", "conid" => "900006", "security_id" => "", "security_id_type" => "",
      "symbol" => "SURMETAL", "description" => "SURE TEST METAL", "position" => "3", "multiplier" => "1",
      "mark_price" => "50.00", "position_value" => "150.00", "currency" => "EUR", "fx_rate_to_base" => "1",
      "cost_basis_price" => "40.00", "report_date" => "2026-05-08", "side" => "Long"
    }

    process!

    assert_equal BigDecimal("3"), holding_for("CMDTY:SURMETAL").qty
    assert_nil Security.find_by(ticker: "SURMETAL")
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
    assert_equal "Buy 100.0 units of BOND:SURCO 3 1/2 06/15/30:900003", bond_trade.name
    assert_equal holding_for("BOND:SURCO 3 1/2 06/15/30:900003").security, bond_trade.entryable.security
  end

  test "accrued interest paid on a bond lands on the bond's security" do
    process!

    entry = @account.entries.find_by!(external_id: "ibkr_cash_9201")
    assert_equal "Interest", entry.entryable.investment_activity_label
    assert_equal Security.find_by!(ticker: "BOND:SURCO 3 1/2 06/15/30:900003").id, entry.entryable.extra["security_id"]
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

    # Undoing the one purchase from today's position leaves nothing: no opening
    # lot of units that no trade explains.
    def assert_no_units_before_the_purchase(bond)
      opening = @account.holding_lots.opening.where(security: bond).sum(:qty)
      assert_equal 0, opening, "undoing the purchase leaves #{opening} units"
    end

    def materialize!
      Holding::Materializer.new(@account.reload, strategy: :reverse).materialize_holdings
    end

    # The position counted per unit, at 0.985 a unit, while the trade is
    # quoted per 100 face as in the fixture.
    def per_unit_position!
      @statement[:open_positions].find { |row| row["asset_category"] == "BOND" }
        .merge!("multiplier" => "1", "mark_price" => "0.985", "cost_basis_price" => "0.9725")
    end

    def bond_rows(statement)
      (statement[:open_positions] + statement[:trades]).select { |row| row["asset_category"] == "BOND" }
    end

    def holding_for(ticker)
      @account.holdings.joins(:security).find_by!(securities: { ticker: ticker }, date: @report_date)
    end
end
