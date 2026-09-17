require "test_helper"

class TradeTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include SqlQueryCapture
  # `Trend#value` is `current - previous`, and `Money#-` keeps the left
  # operand's currency while taking the right one's bare amount without
  # converting or raising. So a disposal priced in the security's currency had
  # a basis denominated in the account's subtracted from it as a plain number,
  # and the difference was then labelled with the disposal's currency.
  #
  # A USD account holding a EUR-listed security: basis 100 USD/share, 2 sold at
  # 150 EUR/share, EUR->USD 1.5 on the trade date. 300 EUR of proceeds is 450
  # USD, less 200 USD of basis, so 250 USD. The unconverted subtraction
  # reported 100 -- and then Reports scaled that wrong difference by the rate.
  test "a disposal priced in another currency converts its proceeds at the trade date" do
    sell = cross_currency_disposal(rate: 1.5)

    assert_equal BigDecimal(250), sell.realized_gain_loss.value.amount
    assert_equal "USD", sell.realized_gain_loss.value.currency.iso_code,
                 "the figure is carried in the currency the position is held in"
  end

  # The same defect at a rate below parity OVERSTATES, so a test at one rate
  # cannot pass by accident of direction. 300 EUR at 0.7 is 210 USD, less 200
  # USD of basis: a 10 USD gain, where the bare subtraction claimed 100.
  test "a disposal at a rate below parity is not overstated" do
    sell = cross_currency_disposal(rate: 0.7)

    assert_equal BigDecimal(10), sell.realized_gain_loss.value.amount
  end

  # No rate for that date means the gain is unknown, not zero and not the
  # figure a rate of 1.0 would produce.
  test "a cross-currency disposal with no rate for its date has no figure" do
    sell = cross_currency_disposal(rate: 1.5, rate_date: Date.new(2026, 3, 9))

    assert_nil sell.realized_gain_loss, "a neighbouring day's rate is not this day's"
  end

  # One query for the rates a whole page of disposals needs, rather than one
  # per foreign disposal. Each disposal falls on its own date, because
  # identical lookups are served by the query cache and a single-date fixture
  # reads as flat whether the preload runs or not.
  test "preloading answers every disposal's rate in one query" do
    account, security = cross_currency_account

    trades = (0..3).map do |offset|
      date = Date.new(2026, 3, 10) + offset
      ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: date, rate: 1.5)
      account.holdings.create!(security: security, date: date, qty: 5, price: 150,
                               amount: BigDecimal(750), currency: "USD", cost_basis: 100)
      create_trade(security, account: account, qty: -2, date: date, price: 150, currency: "EUR").entryable
    end

    Trade.preload_exchange_rates(trades)
    # The ivar directly, as ReportsController does on this branch -- there is
    # no public writer for it upstream yet.
    trades.each { |trade| trade.instance_variable_set(:@preloaded_holdings, account.holdings.to_a) }

    queries = capture_sql_queries { trades.each { |trade| trade.realized_gain_loss } }
      .grep(/exchange_rates/)

    assert_empty queries, "the preload already answered them"
    assert_equal [ BigDecimal(250) ] * 4, trades.map { |t| t.realized_gain_loss.value.amount }
  end

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

  test "a transfer out realises nothing, however it is priced" do
    account, security = position_with_known_cost_basis

    moved = build_negative_trade(account, security, label: "Transfer")
    sold  = build_negative_trade(account, security, label: "Sell")

    # Same sign, same shape, same price — only the label separates a sale from
    # coins walking to another wallet you own.
    assert_nil moved.realized_gain_loss
    assert_not_nil sold.realized_gain_loss
  end

  test "every internal movement label realises nothing" do
    account, security = position_with_known_cost_basis

    Trade::INTERNAL_MOVEMENT_LABELS.each do |label|
      trade = build_negative_trade(account, security, label: label)
      assert_nil trade.realized_gain_loss, "#{label} should not realise a gain"
    end
  end

  private
    # A position whose cost basis is known, which is what makes a fabricated
    # gain possible: without one, realized_gain_loss returns nil for any reason.
    def position_with_known_cost_basis
      family = families(:empty)
      account = family.accounts.create!(name: "Wallet", balance: 100, currency: "USD",
                                        accountable: Investment.new)
      security = Security.find_or_create_by!(ticker: "MOVE") { |s| s.name = "Movable" }
      Holding.create!(account: account, security: security, date: 10.days.ago.to_date,
                      qty: 100, price: 2, amount: 200, currency: "USD", cost_basis: 1)

      [ account, security ]
    end

    def build_negative_trade(account, security, label:)
      account.entries.create!(
        date: 3.days.ago.to_date, name: "out #{label}", amount: 0, currency: "USD",
        entryable: Trade.new(security: security, qty: -40, price: 3, currency: "USD",
                             investment_activity_label: label)
      ).entryable
    end

    # "Exchange" means a currency exchange on cash and is internal there. On a
    # security the label covers currency *or security* exchanges, and a
    # security-for-security exchange can dispose of an appreciated asset — so
    # borrowing Transaction's list erased a realized gain with nothing to show
    # for it.
    test "an exchange is not treated as an internal movement on a trade" do
      assert_not Trade.new(investment_activity_label: "Exchange").internal_movement?
    end

    test "the labels that unambiguously preserve ownership still are" do
      %w[Transfer Sweep\ In Sweep\ Out].each do |label|
        assert Trade.new(investment_activity_label: label).internal_movement?, label
      end
    end

    # The two lists are deliberately different; this fails if one is ever
    # aliased back onto the other.
    test "a trade does not borrow the cash list" do
      assert_includes Transaction::INTERNAL_MOVEMENT_LABELS, "Exchange"
      assert_not_includes Trade::INTERNAL_MOVEMENT_LABELS, "Exchange"
    end

  private
    # A USD account holding a EUR-listed security, with one disposal in it.
    def cross_currency_disposal(rate:, rate_date: Date.new(2026, 3, 10))
      account, security = cross_currency_account
      date = Date.new(2026, 3, 10)

      ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: rate_date, rate: rate)
      account.holdings.create!(security: security, date: date, qty: 5, price: 150,
                               amount: BigDecimal(750), currency: "USD", cost_basis: 100)

      create_trade(security, account: account, qty: -2, date: date, price: 150, currency: "EUR").entryable
    end

    def cross_currency_account
      account = families(:empty).accounts.create!(
        name: "Brokerage", balance: 10_000, currency: "USD", accountable: Investment.new
      )
      security = Security.create!(ticker: "EUX#{SecureRandom.hex(3)}", name: "Euro Listed")

      [ account, security ]
    end
end
