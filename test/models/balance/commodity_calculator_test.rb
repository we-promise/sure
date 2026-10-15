require "test_helper"

class Balance::CommodityCalculatorTest < ActiveSupport::TestCase
  include CommoditiesTestHelper

  setup do
    travel_to Date.new(2026, 10, 15)
    @account = create_commodity_account(currency: "USD")
    @item = create_commodity_item(account: @account, quantity: 2, fineness: 1, purchase_date: Date.new(2026, 10, 12), metal_cost: 4000)
    create_commodity_price(code: "XAU", date: Date.new(2026, 10, 12), price: 2000)
    create_commodity_price(code: "XAU", date: Date.new(2026, 10, 13), price: 2100)
    create_commodity_price(code: "XAU", date: Date.new(2026, 10, 15), price: 2200)
    @item.sales.create!(date: Date.new(2026, 10, 15), quantity: 1, proceeds: 2190, currency: "USD")
  end

  test "values inventory daily from commodity prices, splitting flows from market moves" do
    balances = Balance::CommodityCalculator.new(@account.reload).calculate.index_by(&:date)

    assert_equal Date.new(2026, 10, 12)..Date.new(2026, 10, 15), balances.keys.min..balances.keys.max
    assert_balance balances[Date.new(2026, 10, 12)], balance: 4000, inflows: 4000, outflows: 0, market: 0
    assert_balance balances[Date.new(2026, 10, 13)], balance: 4200, inflows: 0, outflows: 0, market: 200
    assert_balance balances[Date.new(2026, 10, 14)], balance: 4200, inflows: 0, outflows: 0, market: 0 # price carried forward
    assert_balance balances[Date.new(2026, 10, 15)], balance: 2200, inflows: 0, outflows: 2200, market: 200
  end

  test "materialized balances flow into the account balance" do
    Balance::Materializer.new(@account.reload, strategy: :forward).materialize_balances

    assert_equal 2200, @account.reload.balance
    assert_equal 0, @account.cash_balance
    assert_equal [ 4000, 4200, 4200, 2200 ], @account.balances.order(:date).pluck(:end_balance).map(&:to_i)
  end

  test "converts USD prices into the account currency" do
    eur_account = create_commodity_account(currency: "EUR", name: "Vault")
    create_commodity_item(account: eur_account, fineness: 1, purchase_date: Date.new(2026, 10, 15), purchase_currency: "EUR")
    create_rate(from: "USD", to: "EUR", date: Date.new(2026, 10, 14), rate: 0.9)

    balance = Balance::CommodityCalculator.new(eur_account.reload).calculate.sole

    assert_equal 1980, balance.balance # 2200 USD x 0.9 (rate carried forward a day)
  end

  test "an empty inventory produces a zero balance for today" do
    @item.destroy!

    balance = Balance::CommodityCalculator.new(@account.reload).calculate.sole
    assert_equal [ Date.current, 0 ], [ balance.date, balance.balance ]
  end

  private
    def assert_balance(data, balance:, inflows:, outflows:, market:)
      assert_equal [ balance, inflows, outflows, market ].map(&:to_d),
                   [ data.balance, data.non_cash_inflows, data.non_cash_outflows, data.net_market_flows ].map(&:to_d),
                   "balance on #{data.date}"
    end
end
