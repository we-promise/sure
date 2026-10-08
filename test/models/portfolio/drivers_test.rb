require "test_helper"

class Portfolio::DriversTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper

  setup do
    @family = families(:empty) # USD
    @account = create_portfolio_account(family: @family)
    @day_one = Date.new(2026, 3, 2)
    @day_two = Date.new(2026, 3, 3)
  end

  # The fee is already inside the return, because it reduced the
  # closing balance on the day it was charged. Reporting it separately is what
  # lets a user see what it cost them without it being counted twice.
  test "fees reduce the return and are reported separately" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 990, cash_flow: -10
    fee_entry account: @account, date: @day_two, amount: 10

    drivers = drivers_for

    assert_equal BigDecimal("10"), drivers.fees
    assert_equal BigDecimal("0"), drivers.external_net, "a fee is not a withdrawal"
    assert_equal BigDecimal("-10"), drivers.change
    assert drivers.reconciles?
  end

  # This is the defect the drivers table would otherwise ship
  # with. Balance::BaseCalculator#market_value_change_on_date returns 0 unless
  # the account is :investment AND the day carries no valuation, and the forward
  # calculator skips it outright on a valuation day -- so a manually valued
  # account records its entire move in the adjustment columns. A drivers table
  # reading only net_market_flows reports a flat zero for those accounts.
  test "a valuation tracked account reports its move as revaluations not market" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_200, revaluation: 200

    drivers = drivers_for

    assert_equal BigDecimal("0"), drivers.market,
                 "net_market_flows is empty on a valuation day, and pretending otherwise would be a lie"
    assert_equal BigDecimal("200"), drivers.revaluations
    assert_equal BigDecimal("200"), drivers.market_including_revaluations,
                 "callers that just want 'the holdings moved' get one figure"
    assert drivers.reconciles?
  end

  # The local balance never moves; the rate does. Attributing that
  # to the market would say the holdings gained when they did not.
  test "fx effect carries a rate only move and market stays zero" do
    eur = create_portfolio_account(family: @family, currency: "EUR")
    lay_balance account: eur, date: @day_one, opening: 1_000, closing: 1_000

    set_rate from: "EUR", to: "USD", date: @day_one, rate: 1.0
    set_rate from: "EUR", to: "USD", date: @day_two, rate: 1.1

    drivers = drivers_for(account_ids: [ eur.id ])

    assert_equal BigDecimal("0"), drivers.market
    assert_equal BigDecimal("0"), drivers.revaluations
    assert_in_delta 100.0, drivers.fx_effect.to_f, 0.01
    assert drivers.reconciles?
  end

  # The whole table is worthless if the parts do not add up to the
  # whole, and each account shape composes its change differently.
  test "drivers reconcile to the period change for every account shape" do
    # 1. Trade-tracked, single currency: market flow plus income, a fee and a deposit.
    traded = create_portfolio_account(family: @family)
    lay_balance account: traded, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
    lay_balance account: traded, date: @day_two, opening: 1_100, closing: 2_355,
                cash_flow: 1_040, market_flow: 215
    deposit account: traded, date: @day_two, amount: 1_000
    income_trade account: traded, date: @day_two, amount: 50
    fee_entry account: traded, date: @day_two, amount: 10

    traded_drivers = drivers_for(account_ids: [ traded.id ])
    assert traded_drivers.reconciles?, "trade-tracked: #{traded_drivers.to_h.inspect}"
    assert_equal BigDecimal("1000"), traded_drivers.external_net
    assert_equal BigDecimal("50"), traded_drivers.income
    assert_equal BigDecimal("10"), traded_drivers.fees
    assert_equal BigDecimal("315"), traded_drivers.market

    # 2. Valuation-tracked.
    valued = create_portfolio_account(family: @family)
    lay_balance account: valued, date: @day_one, opening: 500, closing: 500
    lay_balance account: valued, date: @day_two, opening: 500, closing: 650, revaluation: 150

    valued_drivers = drivers_for(account_ids: [ valued.id ])
    assert valued_drivers.reconciles?, "valuation-tracked: #{valued_drivers.to_h.inspect}"

    # 3. Foreign currency, with both a local move and a rate move.
    eur = create_portfolio_account(family: @family, currency: "EUR")
    lay_balance account: eur, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: eur, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100
    set_rate from: "EUR", to: "USD", date: @day_one, rate: 1.0
    set_rate from: "EUR", to: "USD", date: @day_two, rate: 1.2

    eur_drivers = drivers_for(account_ids: [ eur.id ])
    assert eur_drivers.reconciles?, "foreign currency: #{eur_drivers.to_h.inspect}"
    assert eur_drivers.fx_effect.positive?, "a strengthening rate is a gain to this family"
  end

  # Regression, and the reason `reconciles?` is worth asserting at all. When
  # fx_effect is defined as the residual of the reconciliation, this returns
  # true for any input whatsoever: every component could be zero while the value
  # moved, and the books still "balanced". fx_effect is measured from the
  # rate change, so an unexplained move is reported as one.
  #
  # The fixture is not an arriving account: an arrival is described by the
  # composition driver, so it would prove nothing here. This one cannot be
  # described: the account is present from the period's first
  # day, and its day-two row opens at 1,200 after day one closed at 1,000 -- a
  # 200 jump that no driver, composition included, describes.
  test "reconciles is falsifiable and reports an unexplained move" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_200, closing: 1_200

    drivers = drivers_for

    assert_equal BigDecimal("0"), drivers.fx_effect,
                 "a family with one currency has no currency movement to report"
    assert_equal BigDecimal("200"), drivers.unexplained
    refute drivers.reconciles?, "a move nothing describes is not explained, and must not be dressed up as one"
  end

  # An arriving account's opening position is described by the
  # composition driver, so the books balance without anything left over.
  test "composition changes reconcile through the composition driver, leaving nothing unexplained" do
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000

    drivers = drivers_for

    assert drivers.reconciles?, "an arrival is described, not unexplained: #{drivers.to_h.inspect}"
    assert_equal BigDecimal("0"), drivers.unexplained
    assert_equal BigDecimal("1000"), drivers.composition
    assert_equal BigDecimal("1000"), drivers.to_h[:composition]
  end

  test "an ordinary period leaves nothing unexplained" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
    lay_balance account: @account, date: @day_two, opening: 1_100, closing: 2_150,
                cash_flow: 1_000, market_flow: 50

    deposit account: @account, date: @day_two, amount: 1_000

    drivers = drivers_for

    assert_equal BigDecimal("0"), drivers.unexplained
    assert drivers.reconciles?
  end

  test "an empty scope reports zeroes rather than raising" do
    drivers = drivers_for(account_ids: [])

    assert_equal BigDecimal("0"), drivers.change
    assert drivers.reconciles?
  end

  # One minor unit of slack and no more. Converting entry flows and balance
  # rows by different paths leaves sub-cent dust in a multi-currency family,
  # which must not read as a failure to reconcile; a cent and a half must.
  test "reconciles allows a residual of up to one minor unit" do
    assert drivers_with_residual(BigDecimal("0.004")).reconciles?
    assert drivers_with_residual(BigDecimal("0.01")).reconciles?, "the boundary itself reconciles"
    refute drivers_with_residual(BigDecimal("0.015")).reconciles?
  end

  private
    def drivers_for(account_ids: [ @account.id ])
      Portfolio::Drivers.new(
        Portfolio::DailyReturns.new(
          account_ids: account_ids,
          currency: @family.currency,
          period: Period.custom(start_date: @day_one, end_date: @day_two)
        )
      )
    end

    def drivers_with_residual(residual)
      row = Portfolio::DailyReturns::Row.new(
        date: @day_one, value_open: BigDecimal("1000"), value_close: BigDecimal("1000") + residual,
        external_flow: 0, composition_flow: 0, income: 0, fees: 0, market: 0,
        revaluations: 0, fx_effect: 0, rate_missing: false, suppressed: false
      )
      Portfolio::Drivers.new(Struct.new(:rows).new([ row ]))
    end
end
