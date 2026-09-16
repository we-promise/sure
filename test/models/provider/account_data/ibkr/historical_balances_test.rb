require "test_helper"

class Provider::AccountData::Ibkr::HistoricalBalancesTest < ActiveSupport::TestCase
  test "equity totals preserve materialized cash and separate trade flows from market movement" do
    rows = project(
      equity_rows: [ { "report_date" => "2026-05-07", "total" => "1000", "cash" => "999" }, { "report_date" => "2026-05-08", "total" => "1200" } ],
      existing_balances: { Date.new(2026, 5, 7) => { cash_balance: BigDecimal("400") }, Date.new(2026, 5, 8) => { cash_balance: BigDecimal("300") } },
      trade_flows: { Date.new(2026, 5, 8) => BigDecimal("100") })
    assert_equal BigDecimal("400"), rows.first[:cash_balance]
    assert_equal BigDecimal("600"), rows.last[:start_non_cash_balance]
    assert_equal BigDecimal("200"), rows.last[:net_market_flows]
    assert_equal BigDecimal("100"), rows.last[:non_cash_adjustments]
    assert_equal BigDecimal("-100"), rows.last[:cash_adjustments]
    assert_equal BigDecimal("0"), rows.first[:net_market_flows]
  end

  test "weekends carry the latest reported total through the frozen current anchor" do
    rows = project(equity_rows: [ { "report_date" => "2026-05-08", "total" => "1200" } ],
      existing_balances: { "2026-05-09" => { cash_balance: BigDecimal("100") } },
      anchor_date: Date.new(2026, 5, 12), observed_on: Date.new(2026, 5, 10))
    assert_equal [ Date.new(2026, 5, 8), Date.new(2026, 5, 9), Date.new(2026, 5, 10) ], rows.map { |row| row[:date] }
    assert_equal [ BigDecimal("1200") ], rows.map { |row| row[:balance] }.uniq
    assert_equal BigDecimal("100"), rows.second[:cash_balance]
    assert_equal BigDecimal("-100"), rows.second[:net_market_flows]
  end

  test "failed FX dates retain their actual materialized total as the following day's starting value" do
    rows = project(equity_rows: [ { "report_date" => "2026-05-06", "total" => "1000" }, { "report_date" => "2026-05-08", "total" => "1200" } ],
      existing_balances: { "2026-05-07" => { cash_balance: BigDecimal("200") } }, failed_fx_dates: [ "2026-05-07" ],
      retained_totals: { "2026-05-07" => BigDecimal("777") })
    assert_equal [ Date.new(2026, 5, 6), Date.new(2026, 5, 8) ], rows.map { |row| row[:date] }
    assert_equal BigDecimal("200"), rows.last[:start_cash_balance]
    assert_equal BigDecimal("577"), rows.last[:start_non_cash_balance]
    assert_equal BigDecimal("623"), rows.last[:net_market_flows]
  end

  test "failed FX dates inside the projection need a retained materialized row" do
    assert_raises(Provider::AccountData::IncompletePage) do
      project(equity_rows: [ { "report_date" => "2026-05-07", "total" => "1000" } ], failed_fx_dates: [ "2026-05-07" ])
    end
    rows = project(equity_rows: [ { "report_date" => "2026-05-07", "total" => "1000" } ], failed_fx_dates: [ "2026-05-06" ])
    assert_equal 2, rows.size
  end

  test "implicit base totals are accepted but BASE SUMMARY and foreign totals are excluded" do
    rows = project(equity_rows: [
      { "report_date" => "2026-05-08", "total" => "1000" },
      { "report_date" => "2026-05-08", "total" => "2000", "currency" => "BASE_SUMMARY" },
      { "report_date" => "2026-05-08", "total" => "3000", "currency" => "EUR" } ])
    assert_equal BigDecimal("1000"), rows.sole[:balance]
    assert_equal "USD", rows.sole[:currency]
  end

  test "conflicting repeated totals malformed money and future data cannot replace history" do
    assert_raises(ArgumentError) { project(equity_rows: [ { "report_date" => "2026-05-08", "total" => "1000" }, { "report_date" => "2026-05-08", "total" => "1001" } ]) }
    assert_raises(ArgumentError) { project(equity_rows: [ { "report_date" => "2026-05-09", "total" => "1000" } ]) }
    assert_raises(ArgumentError) { project(equity_rows: [ { "report_date" => "2026-05-08", "total" => "NaN" } ]) }
    assert_raises(ArgumentError) { project(equity_rows: [], trade_flows: { "2026-05-08" => 1.2 }) }
  end

  test "a retained protected total is not written and becomes the following day's starting value" do
    rows = project(equity_rows: [ { "report_date" => "2026-05-07", "total" => "1000" }, { "report_date" => "2026-05-08", "total" => "1200" } ],
      existing_balances: { "2026-05-07" => { cash_balance: BigDecimal("400") }, "2026-05-08" => { cash_balance: BigDecimal("300") } },
      retained_totals: { "2026-05-07" => BigDecimal("1500") })
    assert_equal Date.new(2026, 5, 8), rows.sole[:date]
    assert_equal BigDecimal("1100"), rows.sole[:start_non_cash_balance]
    assert_equal BigDecimal("-200"), rows.sole[:net_market_flows]
  end

  private
    def project(equity_rows:, currency: "USD", existing_balances: {}, trade_flows: {}, failed_fx_dates: [], retained_totals: {}, anchor_date: Date.new(2026, 5, 8), observed_on: Date.new(2026, 5, 8))
      Provider::AccountData::Ibkr::HistoricalBalances.project(equity_rows: equity_rows, currency: currency, existing_balances: existing_balances,
        trade_flows: trade_flows, failed_fx_dates: failed_fx_dates, retained_totals: retained_totals, anchor_date: anchor_date, observed_on: observed_on)
    end
end
