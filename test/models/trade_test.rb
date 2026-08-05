require "test_helper"

class TradeTest < ActiveSupport::TestCase
  include EntriesTestHelper

  test "build_name generates buy trade name" do
    name = Trade.build_name("buy", 10, "AAPL")
    assert_equal "Buy 10.0 shares of AAPL", name
  end

  test "build_name generates sell trade name" do
    name = Trade.build_name("sell", 5, "MSFT")
    assert_equal "Sell 5.0 shares of MSFT", name
  end

  test "build_name handles absolute value for negative quantities" do
    name = Trade.build_name("sell", -5, "GOOGL")
    assert_equal "Sell 5.0 shares of GOOGL", name
  end

  test "build_name handles decimal quantities" do
    name = Trade.build_name("buy", 0.25, "BTC")
    assert_equal "Buy 0.25 shares of BTC", name
  end

  test "price scale is preserved at 10 decimal places" do
    security = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")

    # up to 10 decimal places — should persist exactly
    precise_price = BigDecimal("12.3456789012")
    trade = Trade.create!(
      security: security,
      price: precise_price,
      qty: 10000,
      currency: "USD",
      investment_activity_label: "Buy"
    )

    trade.reload

    assert_equal precise_price, trade.price
  end

  test "fee defaults to 0" do
    security = Security.create!(ticker: "FEETEST", exchange_operating_mic: "XNAS")
    trade = Trade.create!(
      security: security,
      price: 100,
      qty: 10,
      currency: "USD",
      investment_activity_label: "Buy"
    )

    assert_equal 0, trade.fee
  end

  test "exchange_rate setter stores normalized numeric value in extra" do
    trade = Trade.new
    trade.exchange_rate = "0.91"

    assert_equal 0.91, trade.exchange_rate
    assert_equal 0.91, trade.extra["exchange_rate"]
  end

  test "exchange_rate validation rejects invalid values" do
    trade = Trade.new
    trade.exchange_rate = "invalid"

    assert_not trade.valid?
    assert_includes trade.errors[:exchange_rate], "must be a number"
  end

  test "exchange_rate validation rejects non-finite values" do
    trade = Trade.new
    trade.exchange_rate = "NaN"

    assert_not trade.valid?
    assert_includes trade.errors[:exchange_rate], "must be a number"
  end

  test "price is rounded to 10 decimal places" do
    security = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")

    # over 10 decimal places — will be rounded
    price_with_too_many_decimals = BigDecimal("1.123456789012345")
    trade = Trade.create!(
      security: security,
      price: price_with_too_many_decimals,
      qty: 1,
      currency: "USD",
      investment_activity_label: "Buy"
    )

    trade.reload

    assert_equal BigDecimal("1.1234567890"), trade.price
  end

  test "realized_gain_loss converts holding cost basis into sell trade currency" do
    account = families(:empty).accounts.create!(
      name: "CAD Brokerage",
      balance: 10000,
      cash_balance: 10000,
      currency: "CAD",
      accountable: Investment.new
    )
    security = Security.create!(ticker: "RGNL", name: "Realized Gain Native Lot", exchange_operating_mic: "XNAS")
    buy_date = 5.days.ago.to_date
    sell_date = Date.current

    ExchangeRate.create!(from_currency: "USD", to_currency: "CAD", date: sell_date, rate: 1.30)

    create_trade(security, account: account, qty: 10, date: buy_date, price: 100, currency: "USD")
    sell_entry = create_trade(security, account: account, qty: -4, date: sell_date, price: 150, currency: "CAD")

    account.holdings.create!(
      security: security,
      date: sell_date,
      qty: 6,
      price: 150,
      amount: 900,
      currency: "USD",
      cost_basis: 100,
      cost_basis_source: "calculated"
    )

    trend = sell_entry.trade.realized_gain_loss

    assert_not_nil trend
    assert_equal "CAD", trend.current.currency.iso_code
    assert_equal "CAD", trend.previous.currency.iso_code
    # Proceeds: 150 CAD * 4 = 600 CAD
    # Cost basis: 100 USD * 1.30 * 4 = 520 CAD
    # Gain: 80 CAD
    assert_equal Money.new(600, "CAD"), trend.current
    assert_equal Money.new(520, "CAD"), trend.previous
    assert_equal Money.new(80, "CAD"), trend.value
  end
end
