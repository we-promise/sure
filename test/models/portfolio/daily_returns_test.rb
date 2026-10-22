require "test_helper"

class Portfolio::DailyReturnsTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper

  setup do
    @family = families(:empty) # currency USD
    @account = create_portfolio_account(family: @family)
    @day_one = Date.new(2026, 3, 2)
    @day_two = Date.new(2026, 3, 3)
  end

  # The hand-computed arithmetic:
  #
  #   day 1: 1000 -> 1100, no flow          r = 1100 / 1000       - 1 = 0.10
  #   day 2: 1100 -> 2310, 1000 deposited   r = 2310 / (1100+1000) - 1 = 0.10
  #
  # The deposit belongs in the DENOMINATOR. Put it in the numerator instead
  # (end-of-day convention) and day two reads 2310/1100 - 1 = 1.10 -- a 110%
  # day, produced entirely by the user moving their own money.
  test "start of day flow convention places the flow in the denominator" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
    lay_balance account: @account, date: @day_two, opening: 1_100, closing: 2_310,
                cash_flow: 1_000, market_flow: 210
    deposit account: @account, date: @day_two, amount: 1_000

    rows = daily_returns.rows
    second = rows.last

    assert_equal 2, rows.size
    assert_equal BigDecimal("1100"), second.value_open
    assert_equal BigDecimal("1000"), second.external_flow
    assert_equal BigDecimal("2100"), second.denominator, "the flow must be inside the denominator"

    returns = daily_returns.returns.map(&:last)
    assert_in_delta 0.10, returns.first.to_f, 0.000001
    assert_in_delta 0.10, returns.last.to_f, 0.000001
  end

  # The account does not move in its own currency; the rate does.
  # Because returns are quoted in the family's currency, that is a real 10% day
  # for this family, and it must appear as one.
  test "exchange rate movement alone produces a return" do
    eur = create_portfolio_account(family: @family, currency: "EUR")
    lay_balance account: eur, date: @day_one, opening: 1_000, closing: 1_000

    set_rate from: "EUR", to: "USD", date: @day_one, rate: 1.0
    set_rate from: "EUR", to: "USD", date: @day_two, rate: 1.1

    returns = daily_returns(account_ids: [ eur.id ]).returns.map(&:last)

    assert_in_delta 0.10, returns.last.to_f, 0.000001,
                    "a rate move with a flat local balance is still a return to this family"
  end

  # A full withdrawal leaves V_open + F == 0. Dividing by it raises;
  # allowing a negative denominator through is worse, because it silently
  # reverses the sign of the day's return.
  test "a non positive denominator suppresses the day rather than inverting it" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 0, cash_flow: -1_000
    deposit account: @account, date: @day_two, amount: -1_000

    rows = daily_returns.rows
    second = rows.last

    assert_equal BigDecimal("-1000"), second.external_flow
    assert_equal BigDecimal("0"), second.denominator
    assert second.suppressed, "a zero denominator must be suppressed"
    assert_equal [ @day_two ], daily_returns.suppressed_rows.map(&:date)
    assert_equal BigDecimal("0"), daily_returns.returns.last.last
  end

  # The case the zero test above cannot see. A withdrawal larger than the
  # opening value leaves a NEGATIVE start-of-day capital, and dividing by it
  # flips the sign: here the day's 100 close over a -500 denominator reads as a
  # -120% day. A guard that only refused zero would let that through.
  test "an over-withdrawal suppresses the day rather than reversing its sign" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 100,
                cash_flow: -1_500, market_flow: 600
    deposit account: @account, date: @day_two, amount: -1_500

    second = daily_returns.rows.last

    assert_equal BigDecimal("-500"), second.denominator, "the fixture must reach a negative denominator"
    assert second.suppressed, "a negative denominator must be suppressed"
    assert_equal BigDecimal("0"), daily_returns.returns.last.last,
                 "a suppressed day contributes nothing, not a reversed return"
  end

  # `InvestmentStatement#period_return_trend` converts a missing
  # rate at parity (COALESCE(rate, 1)), which turns 1,000 EUR into 1,000 USD
  # without saying so. A missing pair has to be visible.
  test "a currency pair with no rate is flagged rather than converted at parity" do
    eur = create_portfolio_account(family: @family, currency: "EUR")
    lay_balance account: eur, date: @day_one, opening: 1_000, closing: 1_000
    # No ExchangeRate rows exist for EUR -> USD at all.

    returns = daily_returns(account_ids: [ eur.id ])

    assert returns.rate_missing?, "a pair with no rate anywhere must be flagged"
    refute_equal BigDecimal("1000"), returns.rows.first.value_close,
                 "a missing rate must not silently produce the parity-converted figure"
  end

  test "a buy is internal and does not enter the external flow" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000
    buy_trade account: @account, date: @day_two, qty: 2, price: 100

    assert_equal BigDecimal("0"), daily_returns.rows.last.external_flow,
                 "a buy moves cash into holdings inside the account; it is not a contribution"
  end

  test "a dividend is income rather than an external flow" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_050, cash_flow: 50
    income_trade account: @account, date: @day_two, amount: 50

    row = daily_returns.rows.last

    assert_equal BigDecimal("50"), row.income
    assert_equal BigDecimal("0"), row.external_flow,
                 "classifying income as a flow would cancel it out of the return entirely"
  end

  test "a transaction shaped dividend is income too" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_050, cash_flow: 50
    income_transaction account: @account, date: @day_two, amount: 50

    row = daily_returns.rows.last

    assert_equal BigDecimal("50"), row.income, "the provider shape must not change the classification"
    assert_equal BigDecimal("0"), row.external_flow
  end

  # Excluding an entry hides it from budgets and reports, but
  # Balance::SyncCache still applies it, so the balance moves by it. Left out of
  # the denominator, an excluded 500 deposit read as a 50% day. This reverses
  # the earlier "an excluded entry contributes no flow", which pinned that gap.
  test "an excluded entry still counts as a flow because it moved the balance" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_500, cash_flow: 500
    entry = deposit(account: @account, date: @day_two, amount: 500)
    entry.update!(excluded: true)

    assert_equal BigDecimal("500"), daily_returns.rows.last.external_flow
    assert_in_delta 0.0, daily_returns.returns.last.last.to_f, 0.000001,
                    "the deposit explains the whole move, so the day returned nothing"
  end

  # The one excluded entry the balance does NOT apply: a split parent.
  # Entry#split! marks the parent excluded and its children carry the amount,
  # and Balance::SyncCache skips the parent. Counting excluded entries must not
  # count the parent as well, or the deposit enters the denominator twice.
  test "a split deposit counts once, through its children" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_500, cash_flow: 500
    parent = deposit(account: @account, date: @day_two, amount: 500)
    parent.split!([ { name: "Part one", amount: -300 }, { name: "Part two", amount: -200 } ])

    assert parent.reload.excluded, "split! marks the parent excluded"
    assert_equal BigDecimal("500"), daily_returns.rows.last.external_flow
  end

  test "a disabled account stops contributing after its cut off date" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000

    returns = Portfolio::DailyReturns.new(
      account_ids: [ @account.id ],
      currency: @family.currency,
      period: Period.custom(start_date: @day_one, end_date: @day_two),
      active_until_dates: { @account.id => @day_one }
    )

    assert_equal BigDecimal("1000"), returns.rows.first.value_close
    assert_equal BigDecimal("0"), returns.rows.last.value_close,
                 "the account is closed on day two and must contribute nothing"
  end

  # Regression. Asserting value_close alone was not enough: the account leaving
  # the scope drops it from value_close while value_open still carries
  # yesterday's close, so the ratio read -100% and #chain multiplied the whole
  # period's TWR by zero. Closing a broker made every historical return vanish.
  #
  # Any caller that passes active_until_dates reaches this.
  #
  # The value an account carries out of the scope is a composition OUTFLOW,
  # not a zero-return day. Here the only account leaves entirely, so the
  # denominator is 1,000 - 1,000 = 0 and the non-positive denominator rule
  # still suppresses the day -- for the denominator, not for the departure.
  test "the day an account leaves the scope is suppressed rather than read as a total loss" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000

    returns = Portfolio::DailyReturns.new(
      account_ids: [ @account.id ],
      currency: @family.currency,
      period: Period.custom(start_date: @day_one, end_date: @day_two),
      active_until_dates: { @account.id => @day_one }
    )

    closing_day = returns.rows.last
    assert_equal BigDecimal("0"), returns.returns.to_h.fetch(@day_two),
                 "a full exit contributes nothing to the chain"
    assert closing_day.suppressed, "the denominator is zero once the value has left"

    # The balance did not evaporate, it left the scope, and the composition
    # outflow now describes it: nothing is left unexplained.
    assert_equal BigDecimal("0"), closing_day.unexplained,
                 "the value carried out is a composition flow, not an unexplained move"
    assert_equal BigDecimal("-1000"), closing_day.composition_flow
    assert_equal BigDecimal("0"), closing_day.market
  end

  # Staying moves 1,000 -> 1,050 on day three; Leaving carries 400 out
  # after its cut-off on day two. The only investment return in the period is
  # Staying's 50 on 1,000:
  #
  #   day three: value_open 1,400, departure -400, value_close 1,050
  #   r = 1,050 / (1,400 - 400) - 1 = 0.05
  #
  # Suppressing the departure day instead would report 0% and throw
  # the period's only real gain away.
  test "an account leaving carries its value out and the day keeps the rest of the portfolio's return" do
    day_three = @day_two + 1.day
    leaving = create_portfolio_account(family: @family)
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: day_three, opening: 1_000, closing: 1_050, market_flow: 50
    lay_balance account: leaving, date: @day_one, opening: 400, closing: 400
    lay_balance account: leaving, date: @day_two, opening: 400, closing: 400

    returns = Portfolio::DailyReturns.new(
      account_ids: [ @account.id, leaving.id ],
      currency: @family.currency,
      period: Period.custom(start_date: @day_one, end_date: day_three),
      active_until_dates: { leaving.id => @day_two }
    )

    assert_in_delta 0.05, returns.returns.to_h.fetch(day_three).to_f, 0.000001,
                    "the staying account's 5% survives the other account leaving"
    departure_day = returns.rows.last
    assert_not departure_day.suppressed, "a departure is a flow, not a reason to drop the day"
    assert_equal BigDecimal("-400"), departure_day.composition_flow
    assert_equal BigDecimal("0"), departure_day.unexplained
  end

  # An account whose first balance row falls inside the period, after
  # its first day, brings that row's opening value into the scope. The flat
  # account holds 1,000; Arriving appears on day two holding 500:
  #
  #   day two: value_open 1,000, arrival +500, value_close 1,500
  #   r = 1,500 / (1,000 + 500) - 1 = 0
  #
  # Reading the arrival as return reported a 50% day for a flat portfolio.
  test "an account arriving mid-period brings its opening value as a composition inflow, not a return" do
    arriving = create_portfolio_account(family: @family)
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000
    lay_balance account: arriving, date: @day_two, opening: 500, closing: 500

    returns = daily_returns(account_ids: [ @account.id, arriving.id ])

    assert_in_delta 0.0, returns.returns.to_h.fetch(@day_two).to_f, 0.000001,
                    "money arriving in the scope is not a return"
    arrival_day = returns.rows.last
    assert_equal BigDecimal("500"), arrival_day.composition_flow
    assert_equal BigDecimal("0"), arrival_day.unexplained
  end

  # The same rule on rows the real forward calculator writes: a manual account
  # whose opening anchor falls inside the period. The calculator seeds from the
  # anchor, so the first row opens at 500 with no adjustments.
  test "an arrival written by the forward calculator is measured from its first row's opening balance" do
    manual = create_portfolio_account(family: @family)
    manual.set_opening_anchor_balance(balance: 500, date: @day_two)
    Balance::Materializer.new(manual, strategy: :forward).materialize_balances
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000

    first_row = manual.balances.order(:date).first
    assert_equal @day_two, first_row.date, "the fixture must arrive inside the period, or this proves nothing"
    assert_equal BigDecimal("500"), first_row.start_balance

    returns = daily_returns(account_ids: [ @account.id, manual.id ])

    assert_in_delta 0.0, returns.returns.to_h.fetch(@day_two).to_f, 0.000001
    assert_equal BigDecimal("500"), returns.rows.last.composition_flow
  end

  # The reverse calculator (linked accounts) writes the same shape with an
  # opening anchor: the anchor day's row opens and closes at the anchor total.
  test "an arrival written by the reverse calculator with an opening anchor is measured from its first row's opening balance" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000

    anchored = create_portfolio_account(family: @family)
    anchored.set_opening_anchor_balance(balance: 500, date: @day_two)
    anchored.set_current_balance(500)
    Balance::Materializer.new(anchored, strategy: :reverse).materialize_balances

    first_row = anchored.balances.order(:date).first
    assert_equal @day_two, first_row.date, "the fixture must arrive inside the period, or this proves nothing"
    assert_equal BigDecimal("500"), first_row.start_balance

    returns = daily_returns(account_ids: [ @account.id, anchored.id ])

    assert_in_delta 0.0, returns.returns.to_h.fetch(@day_two).to_f, 0.000001, "an anchored arrival is not a return"
    assert_equal BigDecimal("500"), returns.rows.last.composition_flow
  end

  # Without an anchor, Account::OpeningBalanceManager#opening_date is the day
  # BEFORE the oldest entry, so a 50 deposit on day three gives a first row on
  # day two, opening at 500 derived backwards from the current balance of 550.
  #
  #   day two:   arrival +500, value 1,000 -> 1,500           r = 0
  #   day three: deposit +50,  value 1,500 -> 1,550           r = 1,550 / 1,550 - 1 = 0
  test "an arrival written by the reverse calculator without an opening anchor is measured the same way" do
    day_three = @day_two + 1.day
    [ @day_one, @day_two, day_three ].each { |date| lay_balance account: @account, date: date, opening: 1_000, closing: 1_000 }

    unanchored = create_portfolio_account(family: @family)
    deposit account: unanchored, date: day_three, amount: 50
    unanchored.set_current_balance(550)
    Balance::Materializer.new(unanchored, strategy: :reverse).materialize_balances

    first_row = unanchored.balances.order(:date).first
    assert_equal @day_two, first_row.date, "the fixture must arrive after the period's first day, or this proves nothing"
    assert_equal BigDecimal("500"), first_row.start_balance

    returns = daily_returns(account_ids: [ @account.id, unanchored.id ], end_date: day_three)
    by_date = returns.rows.index_by(&:date)

    assert_in_delta 0.0, returns.returns.to_h.fetch(@day_two).to_f, 0.000001, "an unanchored arrival is not a return"
    assert_in_delta 0.0, returns.returns.to_h.fetch(day_three).to_f, 0.000001, "the next day's deposit is not a return either"
    assert_equal BigDecimal("500"), by_date.fetch(@day_two).composition_flow
    assert_equal BigDecimal("50"), by_date.fetch(day_three).external_flow
  end

  # The arrival is the account's OPENING value, not its closing one: a gain it
  # makes on its first day is a real return.
  #
  #   day two: value_open 1,000, arrival +500, value_close 1,000 + 550 = 1,550
  #   r = 1,550 / (1,000 + 500) - 1 = 0.033333
  test "an account arriving and gaining on its first day keeps that day's gain" do
    arriving = create_portfolio_account(family: @family)
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000
    lay_balance account: arriving, date: @day_two, opening: 500, closing: 550, market_flow: 50

    returns = daily_returns(account_ids: [ @account.id, arriving.id ])

    assert_in_delta 0.033333, returns.returns.to_h.fetch(@day_two).to_f, 0.000001,
                    "the arriving account's first-day gain is a return; its opening value is not"
    assert_equal BigDecimal("500"), returns.rows.last.composition_flow
    assert_equal BigDecimal("0"), returns.rows.last.unexplained
  end

  # An account whose history begins only after its own cut-off never enters the
  # scope: value_close excludes it, so counting its opening value as an arrival
  # would put capital in the denominator that no closing value contains.
  test "an account whose first balance row falls after its cut off never arrives" do
    late = create_portfolio_account(family: @family)
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000
    lay_balance account: late, date: @day_two, opening: 500, closing: 500

    returns = Portfolio::DailyReturns.new(
      account_ids: [ @account.id, late.id ],
      currency: @family.currency,
      period: Period.custom(start_date: @day_one, end_date: @day_two),
      active_until_dates: { late.id => @day_one }
    )

    assert_in_delta 0.0, returns.returns.to_h.fetch(@day_two).to_f, 0.000001
    assert_equal BigDecimal("0"), returns.rows.last.composition_flow
  end

  # An arrival is treated as any start-of-day flow: it is converted at the
  # PREVIOUS day's rate, and that day's rate move on it is a real currency gain.
  #
  #   rates EUR->USD: day one 1.0, day two 1.2
  #   day two: value_open 1,000 USD, arrival 500 EUR x 1.0 = 500 USD
  #            value_close 1,000 + 500 x 1.2 = 1,600 USD
  #   r = 1,600 / (1,000 + 500) - 1 = 0.066667
  #   fx_effect 500 x (1.2 - 1.0) = 100, unexplained 0
  test "a foreign currency arrival converts at the previous day's rate and reconciles" do
    eur = create_portfolio_account(family: @family, currency: "EUR")
    set_rate from: "EUR", to: "USD", date: @day_one, rate: 1.0
    set_rate from: "EUR", to: "USD", date: @day_two, rate: 1.2
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000
    lay_balance account: eur, date: @day_two, opening: 500, closing: 500

    returns = daily_returns(account_ids: [ @account.id, eur.id ])
    arrival_day = returns.rows.last

    assert_in_delta 0.066667, returns.returns.to_h.fetch(@day_two).to_f, 0.000001,
                    "only the rate move on the arrived capital is a return"
    assert_equal BigDecimal("500"), arrival_day.composition_flow
    assert_in_delta 100.0, arrival_day.fx_effect.to_f, 0.000001
    assert_equal BigDecimal("0"), arrival_day.unexplained
  end

  # Not an arrival: an account whose first balance row is the period's first
  # day already contributes its opening value through value_open, so counting
  # it as a composition inflow as well would double it.
  test "an account whose first balance row is the period's first day is not an arrival" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
    lay_balance account: @account, date: @day_two, opening: 1_100, closing: 1_100

    returns = daily_returns

    assert_equal BigDecimal("1000"), returns.rows.first.value_open
    assert_in_delta 0.10, returns.returns.first.last.to_f, 0.000001
    assert_equal [ BigDecimal("0"), BigDecimal("0") ], returns.rows.map(&:composition_flow)
  end

  # Regression for the other half of the same rule. The composition signal was
  # a COUNT of in-window accounts, which falls when ANY account passes its
  # cut-off -- including one that never held anything. A broker connected, never
  # funded and later disabled therefore suppressed a real day for every other
  # account in the portfolio, and #chain multiplied that day in as a zero.
  #
  # Nothing left the scope, so nothing is suppressed: the signal is now the
  # VALUE that departed, measured by departures_by_date, not a headcount.
  test "an empty account reaching its cut off leaves a performing account's day intact" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100

    never_funded = create_portfolio_account(family: @family)

    returns = Portfolio::DailyReturns.new(
      account_ids: [ @account.id, never_funded.id ],
      currency: @family.currency,
      period: Period.custom(start_date: @day_one, end_date: @day_two),
      active_until_dates: { never_funded.id => @day_one }
    )

    closing_day = returns.rows.last

    assert_not closing_day.suppressed,
               "an account that held nothing took nothing with it when it closed"
    assert_in_delta 0.10, returns.returns.to_h.fetch(@day_two).to_f, 0.000001,
                    "the performing account's day survives the other one's cut-off"
  end

  # Regression: an empty foreign-currency account contributes nothing to any
  # figure, so it must not blank the portfolio. The flag was previously raised
  # for any in-scope account whose currency lacked a rate, whether or not it
  # held a balance, so adding an unsynced account suppressed every ratio for
  # every other account too.
  test "an unsynced foreign account holding no balance does not flag a missing rate" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100
    empty_gbp = create_portfolio_account(family: @family, currency: "GBP")

    returns = daily_returns(account_ids: [ @account.id, empty_gbp.id ])

    refute returns.rate_missing?, "an account with no balances cannot be missing a conversion"
    assert_in_delta 0.10, returns.returns.last.last.to_f, 0.000001
  end

  # The same rule one step on: an account that HAS balance rows, every one of
  # them zero, holds nothing either. A zero opening anchor written for an
  # account the user has added but not funded is exactly this, and a zero
  # converts to zero at any rate, so there is no conversion to be missing.
  test "a foreign account whose balance rows are all zero does not flag a missing rate" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100
    zero_gbp = create_portfolio_account(family: @family, currency: "GBP")
    lay_balance account: zero_gbp, date: @day_one, opening: 0, closing: 0
    lay_balance account: zero_gbp, date: @day_two, opening: 0, closing: 0

    returns = daily_returns(account_ids: [ @account.id, zero_gbp.id ])

    refute returns.rate_missing?, "a balance of zero needs no rate to be converted"
    assert_in_delta 0.10, returns.returns.last.last.to_f, 0.000001
  end

  # The control, and the half of the check the closing balance cannot see:
  # an account that OPENED the period holding 50 and withdrew all of it ends
  # every day at zero, yet value_open reads its 50 on the first day and needs
  # the rate to convert it. So the check is about the amounts, not the rows.
  test "a foreign account that opened the period holding a balance still flags a missing rate" do
    gbp = create_portfolio_account(family: @family, currency: "GBP")
    lay_balance account: gbp, date: @day_one, opening: 50, closing: 0, cash_flow: -50
    lay_balance account: gbp, date: @day_two, opening: 0, closing: 0

    assert daily_returns(account_ids: [ gbp.id ]).rate_missing?,
           "an opening balance of 50 GBP has to be converted"
  end

  # The carried-forward half of the same check. A row from before the period
  # opens the period at its END balance, so its historical start_balance is
  # never converted. An account that withdrew everything before the period
  # holds nothing in it and needs no rate.
  test "a carried forward row that closed to zero does not flag a missing rate" do
    gbp = create_portfolio_account(family: @family, currency: "GBP")
    lay_balance account: gbp, date: @day_one - 1.day, opening: 50, closing: 0, cash_flow: -50

    returns = daily_returns(account_ids: [ gbp.id ])

    refute returns.rate_missing?, "a closing balance of zero needs no rate"
    assert_equal BigDecimal("0"), returns.rows.first.value_open
  end

  # Regression: components used to be read from the carried-forward balance row,
  # so a day with no row of its own re-reported the previous day's market flow.
  # Over a gap that multiplied the market driver by the gap's length.
  test "a carried forward balance does not repeat its market flow on later days" do
    day_three = @day_two + 1.day
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
    # No rows for day two or day three: the balance is carried forward.

    rows = daily_returns(end_date: day_three).rows

    assert_equal BigDecimal("100"), rows.first.market
    assert_equal BigDecimal("0"), rows.second.market, "the gap must not re-earn day one's gain"
    assert_equal BigDecimal("0"), rows.third.market
  end

  # An entry whose `excluded` column is NULL rather than false: Ruby reads it as
  # a live flow, and a bare `excluded = false` in SQL evaluates to NULL and
  # drops the row. Left unaligned, the deposit vanishes from the denominator and
  # inflates the day's return.
  test "an entry with a null excluded flag is still counted as a flow" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_500, cash_flow: 500
    entry = deposit(account: @account, date: @day_two, amount: 500)
    entry.update_column(:excluded, nil)

    assert_nil entry.reload.excluded
    assert_equal BigDecimal("500"), daily_returns.rows.last.external_flow
    assert_in_delta 0.0, daily_returns.returns.last.last.to_f, 0.000001,
                    "the deposit explains the whole move, so the day returned nothing"
  end

  # A missing rate on a flow. The account is in the family's currency and its balances
  # convert, but the deposit was recorded in euros and no EUR rate exists.
  # Converting it at parity would put 500 into the denominator as 500 dollars.
  test "a foreign currency flow with no rate is flagged rather than converted at parity" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_500, cash_flow: 500
    deposit account: @account, date: @day_two, amount: 500, currency: "EUR"

    returns = daily_returns

    assert returns.rate_missing?, "an unconvertible flow must be flagged"
    refute_equal BigDecimal("500"), returns.rows.last.external_flow,
                 "the flow must not be converted at parity"
  end

  # A foreign entry moves the balance by what Balance::SyncCache converted it
  # to: the ACCOUNT's currency, on the entry's own date. The flow has to be that
  # same amount, or the gap shows up as a return. Here a 500 EUR deposit lands
  # in a USD account as 600 (the day's 1.2), and that 600 is the flow. Taken
  # straight to the family currency at the previous day's 1.1 it read 550,
  # and the other 50 became a phantom gain.
  test "a foreign currency flow converts into the account's currency on its own date" do
    set_rate from: "EUR", to: "USD", date: @day_one, rate: 1.1
    set_rate from: "EUR", to: "USD", date: @day_two, rate: 1.2
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_600, cash_flow: 600
    deposit account: @account, date: @day_two, amount: 500, currency: "EUR"

    second = daily_returns.rows.last

    assert_equal BigDecimal("600"), second.external_flow
    assert_equal BigDecimal("0"), second.unexplained
    assert_in_delta 0.0, daily_returns.returns.last.last.to_f, 0.000001
  end

  # The second leg: once in the account's currency, the flow joins the opening
  # capital, which is valued at the previous day's rate, so it converts to the
  # family currency at that rate. A GBP account takes a 500 EUR deposit as 400
  # GBP (EUR->GBP 0.8 that day), and 400 GBP at the previous day's 1.25 is 500.
  test "a converted flow then reaches the family currency at the previous day's rate" do
    gbp = create_portfolio_account(family: @family, currency: "GBP")
    set_rate from: "EUR", to: "GBP", date: @day_two, rate: 0.8
    set_rate from: "GBP", to: "USD", date: @day_one, rate: 1.25
    set_rate from: "GBP", to: "USD", date: @day_two, rate: 1.25
    lay_balance account: gbp, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: gbp, date: @day_two, opening: 1_000, closing: 1_400, cash_flow: 400
    deposit account: gbp, date: @day_two, amount: 500, currency: "EUR"

    second = daily_returns(account_ids: [ gbp.id ]).rows.last

    assert_equal BigDecimal("500"), second.external_flow
    assert_equal BigDecimal("0"), second.unexplained
  end

  # Balance::SyncCache converts an entry through ExchangeRate.find_or_fetch_rate:
  # the entry's own date, else the nearest stored rate up to five days back,
  # else the provider. Anything older, or only a later rate, and the entry is
  # dropped from the balance. The flow has to be found the same way, or a
  # deposit the balance never applied joins the denominator and the day reads
  # as a loss of the whole deposit. Here the only EUR rate is six days old and
  # there is no provider in test, so the balance did not move.
  test "a foreign flow whose only rate is more than five days old is flagged, as the balance dropped it" do
    set_rate from: "EUR", to: "USD", date: @day_two - 6.days, rate: 1.1
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000
    deposit account: @account, date: @day_two, amount: 500, currency: "EUR"

    returns = daily_returns

    assert returns.rate_missing?, "the balance could not convert the deposit, so neither can the flow"
    assert_equal BigDecimal("0"), returns.rows.last.external_flow
  end

  # The other side of the window: five days back is still a rate to SyncCache,
  # so the deposit moved the balance and is the flow.
  test "a foreign flow converts at a rate up to five days old, as the balance did" do
    set_rate from: "EUR", to: "USD", date: @day_two - 5.days, rate: 1.1
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_550, cash_flow: 550
    deposit account: @account, date: @day_two, amount: 500, currency: "EUR"

    returns = daily_returns

    refute returns.rate_missing?
    assert_equal BigDecimal("550"), returns.rows.last.external_flow
    assert_equal BigDecimal("0"), returns.rows.last.unexplained
  end

  # SyncCache never carries a rate back, so a deposit dated before the pair's
  # first stored rate was dropped from the balance too.
  test "a foreign flow with only a later rate is flagged, as the balance cannot carry a rate back" do
    set_rate from: "EUR", to: "USD", date: @day_two + 1.day, rate: 1.1
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000
    deposit account: @account, date: @day_two, amount: 500, currency: "EUR"

    returns = daily_returns

    assert returns.rate_missing?
    assert_equal BigDecimal("0"), returns.rows.last.external_flow
  end

  # An entry can carry its own rate (extra["exchange_rate"]), which
  # Balance::SyncCache prefers to the table's. The flow must use it too.
  test "a flow carrying its own exchange rate converts at that rate" do
    set_rate from: "EUR", to: "USD", date: @day_one, rate: 1.1
    set_rate from: "EUR", to: "USD", date: @day_two, rate: 1.2
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_625, cash_flow: 625
    entry = deposit(account: @account, date: @day_two, amount: 500, currency: "EUR")
    entry.entryable.update!(exchange_rate: 1.25)

    second = daily_returns.rows.last

    assert_equal BigDecimal("625"), second.external_flow
    assert_equal BigDecimal("0"), second.unexplained
  end

  # With a rate of its own, the entry converted in the balance even though the
  # table has no pair for it, so there is nothing missing to flag.
  test "a flow carrying its own rate with no stored pair does not flag a missing rate" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_625, cash_flow: 625
    entry = deposit(account: @account, date: @day_two, amount: 500, currency: "EUR")
    entry.entryable.update!(exchange_rate: 1.25)

    returns = daily_returns

    refute returns.rate_missing?, "the entry's own rate is a rate"
    assert_equal BigDecimal("625"), returns.rows.last.external_flow
  end

  # A zero amount converts to zero at any rate, so it cannot be short of one.
  test "a zero amount flow in a currency with no rate does not flag a missing rate" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100
    deposit account: @account, date: @day_two, amount: 0, currency: "EUR"

    returns = daily_returns

    refute returns.rate_missing?, "nothing needed converting"
    assert_in_delta 0.10, returns.returns.last.last.to_f, 0.000001
  end

  # An account whose history predates the family's first stored rate converts
  # at the earliest rate after it, rather than being flagged or taken at 1.
  test "a balance before the first stored rate converts at the earliest rate after it" do
    eur = create_portfolio_account(family: @family, currency: "EUR")
    set_rate from: "EUR", to: "USD", date: @day_two + 5.days, rate: 1.2
    lay_balance account: eur, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: eur, date: @day_two, opening: 1_000, closing: 1_000

    returns = daily_returns(account_ids: [ eur.id ])

    refute returns.rate_missing?, "a rate on file is a rate, however far ahead"
    assert_equal BigDecimal("1200"), returns.rows.last.value_close
  end

  # The balances stop at the cut-off date; the flows must stop with them, or a
  # deposit lands in the denominator of a day the account is no longer in.
  test "a flow after an account's cut off date is not counted" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    deposit account: @account, date: @day_two, amount: 500

    returns = Portfolio::DailyReturns.new(
      account_ids: [ @account.id ],
      currency: @family.currency,
      period: Period.custom(start_date: @day_one, end_date: @day_two),
      active_until_dates: { @account.id => @day_one }
    )

    assert_equal BigDecimal("0"), returns.rows.last.external_flow
  end

  # Transfer validates each leg as unique, but the only unique index is on the
  # pair, so a writer that skips validations (insert_all) or two matchers
  # racing can link one outflow to two transfers. The flow must still count
  # once: summed per transfer row, the 400 left twice and the day read -40%
  # on a portfolio that only moved money out.
  test "an outflow linked to two transfers counts once" do
    other = create_portfolio_account(family: @family)
    stray = create_portfolio_account(family: @family)
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 600, cash_flow: -400
    transfer = Transfer::Creator.new(
      family: @family, source_account_id: @account.id, destination_account_id: other.id,
      date: @day_two, amount: 400
    ).create

    single = daily_returns.rows.last.external_flow

    stray_inflow = deposit(account: stray, date: @day_two, amount: 400)
    Transfer.insert_all([ {
      inflow_transaction_id: stray_inflow.entryable_id,
      outflow_transaction_id: transfer.outflow_transaction_id,
      amount: 400, status: "confirmed",
      created_at: transfer.created_at + 1.minute, updated_at: transfer.created_at + 1.minute
    } ])

    assert_equal 2, Transfer.where(outflow_transaction_id: transfer.outflow_transaction_id).count
    assert_equal BigDecimal("-400"), single
    assert_equal single, daily_returns.rows.last.external_flow, "a second transfer row must not count the outflow again"
    assert_in_delta 0.0, daily_returns.returns.last.last.to_f, 0.000001
  end

  # The flow scope is the accounts the series values, and only those. Money
  # sent to an account outside the series has left the series: it is an
  # external outflow, so it leaves the denominator as it leaves the close and
  # the day returns what the portfolio earned, which is nothing. Classified as
  # internal, the outflow stays in the denominator and the day reads -40%.
  test "a transfer to an account outside the series is a flow out, not a loss" do
    other = create_portfolio_account(family: @family)
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 600, cash_flow: -400
    Transfer::Creator.new(
      family: @family, source_account_id: @account.id, destination_account_id: other.id,
      date: @day_two, amount: 400
    ).create

    second = daily_returns.rows.last

    assert_equal BigDecimal("-400"), second.external_flow
    assert_in_delta 0.0, daily_returns.returns.last.last.to_f, 0.000001,
                    "moving money out of the series is not a loss"
  end

  # An account past its cut-off is outside the scope from the next day on, for
  # the flows as for the balances. Classified against the static ids, a
  # transfer from a live account to it was internal, the cut-off account's leg
  # was dropped by the flow window, and the live account's 400 drop read as a
  # 40% loss.
  test "a transfer to an account past its cut off is a flow out of the series" do
    day_three = @day_two + 1.day
    closed = create_portfolio_account(family: @family)
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: day_three, opening: 1_000, closing: 600, cash_flow: -400
    Transfer::Creator.new(
      family: @family, source_account_id: @account.id, destination_account_id: closed.id,
      date: day_three, amount: 400
    ).create

    returns = Portfolio::DailyReturns.new(
      account_ids: [ @account.id, closed.id ], currency: @family.currency,
      period: Period.custom(start_date: @day_one, end_date: day_three),
      active_until_dates: { closed.id => @day_two }
    )

    assert_equal BigDecimal("-400"), returns.rows.last.external_flow
    assert_in_delta 0.0, returns.returns.last.last.to_f, 0.000001
  end

  # The boundary's other side: on the cut-off date itself both accounts are in
  # the scope, so the same transfer is internal and moves nothing.
  test "a transfer to an account on its cut off date is still internal" do
    closed = create_portfolio_account(family: @family)
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 600, cash_flow: -400
    lay_balance account: closed, date: @day_one, opening: 0, closing: 0
    lay_balance account: closed, date: @day_two, opening: 0, closing: 400, cash_flow: 400
    Transfer::Creator.new(
      family: @family, source_account_id: @account.id, destination_account_id: closed.id,
      date: @day_two, amount: 400
    ).create

    returns = Portfolio::DailyReturns.new(
      account_ids: [ @account.id, closed.id ], currency: @family.currency,
      period: Period.custom(start_date: @day_one, end_date: @day_two),
      active_until_dates: { closed.id => @day_two }
    )

    assert_equal BigDecimal("0"), returns.rows.last.external_flow
    assert_in_delta 0.0, returns.returns.last.last.to_f, 0.000001
  end

  # There is no second, wider "inside" to pass, and no guard of the class's
  # own: Ruby refuses the unknown keyword, which is the point. The message is
  # pinned so that any other ArgumentError -- a new required keyword, say --
  # fails this rather than passing it without checking the scope at all.
  test "the flow scope cannot be widened beyond the accounts in the series" do
    error = assert_raises(ArgumentError) do
      Portfolio::DailyReturns.new(
        account_ids: [ @account.id ], currency: @family.currency,
        period: Period.custom(start_date: @day_one, end_date: @day_two),
        scope_account_ids: [ @account.id, create_portfolio_account(family: @family).id ]
      )
    end
    assert_match(/unknown keyword: :scope_account_ids/, error.message)
  end

  # The levels are multiplied by flows_factor and the flows are not, so on a
  # liability the flows would carry the wrong sign against its balance and
  # nothing would flag it. Refused outright until a caller needs liabilities.
  test "a liability account in the series is refused" do
    loan = @family.accounts.create!(name: "Mortgage", balance: 5_000, currency: "USD", accountable: Loan.new)
    lay_balance account: loan, date: @day_one, opening: 5_000, closing: 5_000
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000

    assert_equal "liability", loan.reload.classification, "precondition: the Loan is a liability"

    [ [ loan.id ], [ @account.id, loan.id ] ].each do |account_ids|
      error = assert_raises(ArgumentError) { daily_returns(account_ids: account_ids).rows }
      assert_match(/liabilit/, error.message)
    end
  end

  test "investment and crypto accounts are accepted" do
    crypto = @family.accounts.create!(name: "Wallet", balance: 500, currency: "USD", accountable: Crypto.new)
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: crypto, date: @day_one, opening: 500, closing: 500

    assert_equal 1, daily_returns(account_ids: [ @account.id, crypto.id ], end_date: @day_one).rows.size
  end

  # The classifier's CASE arrives already sanitized and full of quoted labels.
  # Handed back through sanitize_sql_array with the rest of the query, any
  # `:word` inside one of those literals is read as a bind variable, and the
  # query raises before it runs. No label contains one today; this makes one
  # that does, and the rows must come back unchanged.
  test "a colon word inside the classifier's sql is not read as a bind" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 2_000, cash_flow: 1_000
    deposit account: @account, date: @day_two, amount: 1_000

    expected = daily_returns.rows
    original = Portfolio::FlowClassifier.new(scope_account_ids: [ @account.id ]).sql_case
    Portfolio::FlowClassifier.any_instance.stubs(:sql_case)
      .returns("CASE WHEN false THEN ':probe' ELSE (#{original}) END")

    probed = daily_returns.rows

    assert_equal BigDecimal("1000"), probed.last.external_flow, "the classifier still decides the flow"
    assert_equal expected, probed
  end

  # The fixture builder guards these tests' own arithmetic, so it has to check
  # it at the precision the rows are stored at. These components add up as
  # given, but `balances` keeps four decimal places: stored, each 0.00005
  # becomes 0.0001 and the row's end_balance is 0.0002 against a balance of
  # 0.0001, a day that no longer reconciles.
  test "the balance builder refuses an amount finer than balances store" do
    error = assert_raises(ArgumentError) do
      lay_balance account: @account, date: @day_one, opening: "0.00005", closing: "0.0001", cash_flow: "0.00005"
    end

    assert_match "finer than the 4 decimal places", error.message
    assert_empty @account.balances.reload, "nothing is written for a refused day"

    lay_balance account: @account, date: @day_one, opening: "0.0001", closing: "0.0002", cash_flow: "0.0001"
    assert_equal BigDecimal("0.0002"), @account.balances.reload.sole.end_balance,
                 "four decimal places is the stored scale and is accepted"
  end

  test "returns are empty without accounts" do
    returns = Portfolio::DailyReturns.new(
      account_ids: [],
      currency: @family.currency,
      period: Period.custom(start_date: @day_one, end_date: @day_two)
    )

    assert_empty returns.rows
    assert_empty returns.returns
    refute returns.any?
  end

  # Regression. When the period starts after the last balance row, that row is
  # carried forward by the `lb` lateral. It was read for BOTH boundaries --
  # value_close from its end_balance, value_open from its start_balance -- so
  # the first day of the period re-reported a change that had already happened
  # before the period began, and left the difference in #unexplained.
  #
  # Here day one moved 1,000 -> 1,100 and the period starts the day after. The
  # portfolio does nothing in the period, so every day must return zero; reading
  # start_balance gave the first day day-one's +10% a second time.
  test "a balance row carried in from before the period opens at its closing level" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
    day_three = @day_two + 1.day

    rows = Portfolio::DailyReturns.new(
      account_ids: [ @account.id ],
      currency: @family.currency,
      period: Period.custom(start_date: @day_two, end_date: day_three)
    ).rows

    first = rows.first
    assert_equal BigDecimal("1100"), first.value_open,
                 "the carried row's closing level is the opening value, not its start_balance"
    assert_equal BigDecimal("1100"), first.value_close
    assert_equal BigDecimal("0"), first.unexplained,
                 "nothing happened in the period, so nothing is unexplained"
  end

  private
    def daily_returns(account_ids: [ @account.id ], start_date: @day_one, end_date: @day_two)
      Portfolio::DailyReturns.new(
        account_ids: account_ids,
        currency: @family.currency,
        period: Period.custom(start_date: start_date, end_date: end_date)
      )
    end
end
