require "test_helper"

class CommodityTest < ActiveSupport::TestCase
  include CommoditiesTestHelper

  setup do
    @family = families(:empty)
  end

  test "lists enabled metals from configuration" do
    assert_equal %w[XAU XAG XPT], Commodity.metals.map(&:code)
    assert_equal BigDecimal("0.9999"), Commodity.metal("XAU").fineness_for("coin")
    assert_not Commodity.metal("XPD").enabled
  end

  test "net worth includes commodities as their own asset class" do
    @family.accounts.create!(name: "Cash", currency: "USD", balance: 1000, accountable: Depository.new)
    @family.accounts.create!(name: "Brokerage", currency: "USD", balance: 5000, accountable: Investment.new)
    account = create_commodity_account(family: @family)
    account.update!(balance: 2300)

    balance_sheet = BalanceSheet.new(@family)
    commodities = balance_sheet.assets.account_groups.find { |g| g.key == "commodity" }

    assert_equal 1000 + 5000 + 2300, balance_sheet.net_worth
    assert_equal "Commodities", commodities.name
    assert_equal [ account ], commodities.accounts.map(&:account)
    investments = balance_sheet.assets.account_groups.find { |g| g.key == "investment" }
    assert_not_includes investments.accounts.map(&:account), account
  end

  test "metals never become securities, holdings or trades, nor appear in investment reports" do
    travel_to Date.new(2026, 10, 15)
    account = create_commodity_account(family: @family)
    create_commodity_item(account: account, purchase_date: 3.days.ago.to_date)
    create_commodity_price(code: "XAU", date: 3.days.ago.to_date, price: 2500)

    assert_no_difference [ "Security.count", "Holding.count", "Trade.count", "Entry.count" ] do
      Balance::Materializer.new(account.reload, strategy: :forward).materialize_balances
    end

    assert account.reload.balance.positive?
    statement = @family.investment_statement
    assert_not_includes statement.investment_accounts, account
    assert_equal 0, statement.portfolio_value
    assert_empty statement.current_holdings
  end
end
