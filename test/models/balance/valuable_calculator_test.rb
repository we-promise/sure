require "test_helper"

class Balance::ValuableCalculatorTest < ActiveSupport::TestCase
  setup do
    travel_to Date.new(2026, 10, 15)
    @account = accounts(:investment).family.accounts.create!(name: "Physical Gold", currency: "USD", balance: 0, accountable: Valuable.new)
    # One troy ounce of fine gold per piece.
    @bar = @account.valuable.lots.create!(description: "Bar", acquired_on: Date.new(2026, 10, 12), weight: 1, weight_unit: "troy_ounce", karat: 24, quantity: 2, cost_amount: 3_900)
    rate(Date.new(2026, 10, 12), 2_000)
    rate(Date.new(2026, 10, 13), 2_100)
    rate(Date.new(2026, 10, 15), 2_200)
  end

  test "values items daily from stored rates, splitting purchases from market moves" do
    balances = calculate

    assert_equal (Date.new(2026, 10, 12)..Date.new(2026, 10, 15)).to_a, balances.keys
    assert_balance balances[Date.new(2026, 10, 12)], balance: 4_000, inflows: 4_000, market: 0
    assert_balance balances[Date.new(2026, 10, 13)], balance: 4_200, inflows: 0, market: 200
    assert_balance balances[Date.new(2026, 10, 14)], balance: 4_200, inflows: 0, market: 0 # rate carried forward
    assert_balance balances[Date.new(2026, 10, 15)], balance: 4_400, inflows: 0, market: 200
  end

  test "a later purchase is an inflow on its day" do
    @account.valuable.lots.create!(description: "Coin", acquired_on: Date.new(2026, 10, 14), weight: 1, weight_unit: "troy_ounce", karat: 24, cost_amount: 2_050)

    assert_balance calculate[Date.new(2026, 10, 14)], balance: 6_300, inflows: 2_100, market: 0
  end

  test "carries forward a rate stored before the first purchase" do
    ExchangeRate.where(from_currency: "XAU").delete_all
    rate(Date.new(2026, 10, 9), 1_900)

    assert_equal 3_800, calculate[Date.new(2026, 10, 12)].balance
  end

  test "values a spot item at cost until a rate is stored" do
    ExchangeRate.where(from_currency: "XAU").delete_all

    assert_equal [ 3_900 ], calculate.values.map(&:balance).uniq
  end

  test "values manual items at their manual value" do
    @bar.update!(manual_value: 5_000)

    assert_equal [ 5_000 ], calculate.values.map(&:balance).uniq
  end

  test "reads only rates in the account currency" do
    @account.update_columns(currency: "EUR")
    @account.valuable.lots.update_all(currency: "EUR")
    ExchangeRate.create!(from_currency: "XAU", to_currency: "EUR", date: Date.new(2026, 10, 12), rate: 1_800)

    assert_equal [ 3_600 ], calculate.values.map(&:balance).uniq
  end

  test "an empty collection produces a zero balance for today" do
    @bar.destroy!

    balance = Balance::ValuableCalculator.new(@account.reload).calculate.sole
    assert_equal [ Date.current, 0 ], [ balance.date, balance.balance ]
  end

  test "materializes daily balances into the account balance" do
    Balance::Materializer.new(@account.reload, strategy: :forward).materialize_balances

    assert_equal 4_400, @account.reload.balance
    assert_equal 0, @account.cash_balance
    assert_equal [ 4_000, 4_200, 4_200, 4_400 ], @account.balances.order(:date).pluck(:end_balance).map(&:to_i)
  end

  private
    def rate(date, value)
      ExchangeRate.create!(from_currency: "XAU", to_currency: "USD", date: date, rate: value, source: "yahoo_futures", provisional: true)
    end

    def calculate
      Balance::ValuableCalculator.new(@account.reload).calculate.index_by(&:date)
    end

    def assert_balance(data, balance:, inflows:, market:)
      assert_equal [ balance, inflows, market ].map(&:to_d),
                   [ data.balance, data.non_cash_inflows, data.net_market_flows ].map(&:to_d),
                   "balance on #{data.date}"
    end
end
