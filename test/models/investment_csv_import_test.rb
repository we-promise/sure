require "test_helper"

class InvestmentCsvImportTest < ActiveSupport::TestCase
  test "imports contributions with loose headers and kind synonyms" do
    account = accounts(:investment)
    csv = "Date,Amount,Type,Memo\n01/15/2025,\"$1,000.00\",Employee,Payroll\n2025-01-15,250,Match,\n2025-03-01,(300.00),distribution,Cash out\n,5,contribution,\n"

    result = InvestmentCsvImport.new(account: account, content: csv, kind: "contributions").import!

    assert_equal 3, result.created
    assert_equal 1, result.skipped
    records = account.account_contributions.order(:date, :kind).to_a
    assert_equal %w[contribution employer_contribution withdrawal], records.map(&:kind)
    assert_equal [ 1000, 250, -300 ], records.map(&:amount)
    assert records.all?(&:from_csv?)
  end

  test "imports vests and groups them into grants" do
    account = accounts(:other_asset)
    csv = "grant_id,grant_date,vest_date,units,net_proceeds\nRS1,2025-03-01,2026-03-15,60,\nRS1,2025-03-01,2026-06-15,55,\"9,876.54\"\nRR2,Feb-10-2025,2026-02-20,40,4321.00\n"

    result = InvestmentCsvImport.new(account: account, content: csv, kind: "equity_grants", default_ticker: "ACME").import!

    assert_equal 3, result.created
    assert_equal 2, account.equity_grants.count
    rs1 = account.equity_grants.find_by!(grant_identifier: "RS1")
    assert_equal "ACME", rs1.ticker
    assert_equal [ 60, 55 ], rs1.vests.map(&:units)
    assert_equal BigDecimal("9876.54"), rs1.vests.last.net_proceeds
    assert_equal Date.new(2025, 2, 10), account.equity_grants.find_by!(grant_identifier: "RR2").grant_date
  end

  test "importing the same vests twice does not duplicate them" do
    account = accounts(:other_asset)
    csv = "grant_id,ticker,vest_date,units\nRS1,ACME,2026-03-15,60\n"

    2.times { InvestmentCsvImport.new(account: account, content: csv, kind: "equity_grants").import! }

    assert_equal 1, EquityVest.joins(:equity_grant).where(equity_grants: { account_id: account.id }).count
  end

  test "vests without a ticker are reported" do
    result = InvestmentCsvImport.new(account: accounts(:other_asset), content: "grant_id,vest_date,units\nRS1,2026-03-15,60\n", kind: "equity_grants").import!

    assert_equal 0, result.created
    assert_equal 1, result.errors.size
  end
end
