require "test_helper"

class EquityGrant::CsvImportTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment)
    @account.investment.update!(subtype: "stock_plan")
  end

  test "imports vests and groups them into grants" do
    csv = "grant_id,grant_date,vest_date,units,net_proceeds\nRS1,2025-03-01,2026-03-15,60,\nRS1,2025-03-01,2026-06-15,55,\"9,876.54\"\nRR2,Feb-10-2025,2026-02-20,40,4321.00\n"

    result = import(csv, default_ticker: "ACME")

    assert_equal 3, result.created
    rs1 = @account.equity_grants.find_by!(grant_identifier: "RS1")
    assert_equal "ACME", rs1.ticker
    assert_equal [ 60, 55 ], rs1.vests.map(&:units)
    assert_equal BigDecimal("9876.54"), rs1.vests.last.net_proceeds
    assert_equal Date.new(2025, 2, 10), @account.equity_grants.find_by!(grant_identifier: "RR2").grant_date
  end

  test "reads decimal commas and parenthesised amounts" do
    import("grant_id,ticker,vest_date,units,net_proceeds\nRS1,ACME,2026-03-15,60,\"1.234,56\"\n")

    assert_equal BigDecimal("1234.56"), @account.equity_grants.first.vests.first.net_proceeds
  end

  test "reports a date it can't read instead of dropping the row silently" do
    result = import("grant_id,ticker,vest_date,units\nRS1,ACME,13/45/2026,60\n")

    assert_equal 0, result.created
    assert_match "13/45/2026", result.errors.first
  end

  test "importing the same vests twice does not duplicate them" do
    csv = "grant_id,ticker,vest_date,units\nRS1,ACME,2026-03-15,60\n"

    2.times { import(csv) }

    assert_equal 1, EquityVest.joins(:equity_grant).where(equity_grants: { account_id: @account.id }).count
  end

  test "vests without a ticker are reported" do
    result = import("grant_id,vest_date,units\nRS1,2026-03-15,60\n")

    assert_equal 0, result.created
    assert_equal 1, result.errors.size
  end

  private
    def import(csv, default_ticker: nil)
      EquityGrant::CsvImport.new(account: @account, content: csv, default_ticker: default_ticker).import!
    end
end
