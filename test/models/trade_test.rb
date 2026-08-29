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

  test "realized_gain_loss prefers non-zero native holding over same-date account-currency orphan" do
    account = families(:empty).accounts.create!(
      name: "CAD Brokerage Tie Break",
      balance: 10000,
      cash_balance: 10000,
      currency: "CAD",
      accountable: Investment.new
    )
    security = Security.create!(ticker: "RGTB", name: "Realized Gain Tie Break", exchange_operating_mic: "XNAS")
    buy_date = 5.days.ago.to_date
    sell_date = Date.current

    ExchangeRate.create!(from_currency: "USD", to_currency: "CAD", date: sell_date, rate: 1.30)

    create_trade(security, account: account, qty: 10, date: buy_date, price: 100, currency: "USD")
    sell_entry = create_trade(security, account: account, qty: -4, date: sell_date, price: 150, currency: "CAD")

    # Neutralized recoverability stub in account currency (would win a naive prefer-CAD pick).
    orphan = account.holdings.create!(
      security: security,
      date: sell_date,
      qty: 0,
      price: 195,
      amount: 0,
      currency: "CAD",
      cost_basis: 999,
      cost_basis_source: "manual",
      cost_basis_locked: true
    )
    native = account.holdings.create!(
      security: security,
      date: sell_date,
      qty: 6,
      price: 150,
      amount: 900,
      currency: "USD",
      cost_basis: 100,
      cost_basis_source: "calculated"
    )

    trade = sell_entry.trade

    # DB path
    trend = trade.realized_gain_loss
    assert_not_nil trend
    assert_equal Money.new(520, "CAD"), trend.previous

    # Preloaded path must use the same tie-break (not max_by date alone / CAD-first).
    trade.instance_variable_set(:@preloaded_holdings, [ orphan, native ])
    trade.remove_instance_variable(:@realized_gain_loss) if trade.instance_variable_defined?(:@realized_gain_loss)

    preloaded_trend = trade.realized_gain_loss
    assert_not_nil preloaded_trend
    assert_equal Money.new(520, "CAD"), preloaded_trend.previous
  end

  test "realized_gain_loss returns nil when holding cost basis cannot be converted" do
    account = families(:empty).accounts.create!(
      name: "CAD Brokerage Missing FX",
      balance: 10000,
      cash_balance: 10000,
      currency: "CAD",
      accountable: Investment.new
    )
    security = Security.create!(ticker: "RGNLFX", name: "Realized Gain Missing FX", exchange_operating_mic: "XNAS")
    buy_date = 5.days.ago.to_date
    sell_date = Date.current

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

    # No USD→CAD rate for the sell date — exchange_to raises Money::ConversionError
    assert_nil sell_entry.trade.realized_gain_loss
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
end
