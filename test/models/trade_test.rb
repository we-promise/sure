require "test_helper"

class TradeTest < ActiveSupport::TestCase
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
end
