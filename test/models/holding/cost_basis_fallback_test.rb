require "test_helper"

class Holding::CostBasisFallbackTest < ActiveSupport::TestCase
  include EntriesTestHelper, SecuritiesTestHelper

  setup do
    @account = families(:empty).accounts.create!(name: "Test Brokerage", balance: 20000, cash_balance: 0, currency: "USD", accountable: Investment.new)
    @security = create_security("AMZN", prices: [ { date: Date.current, price: 216.00 } ])
    @holding = @account.holdings.create!(date: Date.current, security: @security, qty: 15, price: 216, amount: 3240, currency: "USD")
  end

  # The fallback replays the trades through the calculators' tracker. As an
  # average of every purchase ever made, it still counted the first round of a
  # position sold in full and bought again.
  test "the fallback starts a position bought again after a full close from a clean basis" do
    create_trade(@security, account: @account, qty: 10, price: 100.00, date: 3.days.ago.to_date)
    create_trade(@security, account: @account, qty: -10, price: 120.00, date: 2.days.ago.to_date)
    create_trade(@security, account: @account, qty: 5, price: 200.00, date: 1.day.ago.to_date)

    assert_equal Money.new(200), average_cost
  end

  # A sale's gain is measured against the holding on its own date, which after
  # a full close holds nothing, so that holding keeps what the units cost.
  test "the fallback keeps the cost of what a position held on the day it closes" do
    create_trade(@security, account: @account, qty: 10, price: 100.00, date: 2.days.ago.to_date)
    create_trade(@security, account: @account, qty: 5, price: 130.00, date: 1.day.ago.to_date)
    create_trade(@security, account: @account, qty: -15, price: 150.00, date: Date.current)

    # (10 * 100 + 5 * 130) / 15 = 1,650 / 15
    assert_equal Money.new(110), average_cost
  end

  # Units moved in have a cost nothing here knows, but only while they are held.
  test "the fallback knows the basis again once moved-in units are sold in full" do
    moved_in = create_trade(@security, account: @account, qty: 5, price: 100.00, date: 4.days.ago.to_date)
    moved_in.entryable.update!(investment_activity_label: "Transfer")
    create_trade(@security, account: @account, qty: -5, price: 120.00, date: 3.days.ago.to_date)
    create_trade(@security, account: @account, qty: 10, price: 150.00, date: 1.day.ago.to_date)

    assert_equal Money.new(150), average_cost
  end

  test "the fallback keeps the basis unknown while moved-in units are held" do
    moved_in = create_trade(@security, account: @account, qty: 5, price: 100.00, date: 2.days.ago.to_date)
    moved_in.entryable.update!(investment_activity_label: "Transfer")
    create_trade(@security, account: @account, qty: 10, price: 150.00, date: 1.day.ago.to_date)

    assert_nil average_cost
  end

  # Units held before the first imported trade: the replay does not know them,
  # so a sale of them must not leave it short, holding less than nothing.
  test "the fallback starts from a clean basis after a sale of units held before the imported trades" do
    create_trade(@security, account: @account, qty: -10, price: 120.00, date: 2.days.ago.to_date)
    create_trade(@security, account: @account, qty: 5, price: 200.00, date: 1.day.ago.to_date)

    assert_equal Money.new(200), average_cost
  end

  # A split changes the share count, not the money invested. Summed as they
  # stood, the purchases mixed pre- and post-split units.
  test "the fallback carries the cost across a split" do
    create_trade(@security, account: @account, qty: 10, price: 100.00, date: 3.days.ago.to_date)
    Security::Split.create!(security: @security, ex_date: 2.days.ago.to_date, numerator: 2, denominator: 1, source: "manual")
    create_trade(@security, account: @account, qty: 10, price: 60.00, date: 1.day.ago.to_date)

    # (10 * 100 + 10 * 60) / (10 * 2 + 10) = 1,600 / 30
    assert_in_delta BigDecimal("53.333333"), average_cost.amount, BigDecimal("0.000001")
  end

  private
    def average_cost
      Holding::CostBasisFallback.new(@holding).average_cost
    end
end
