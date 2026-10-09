require "test_helper"

class Portfolio::PerformanceTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper
  include SqlQueryCapture

  setup do
    @family = families(:empty) # USD
    @account = create_portfolio_account(family: @family)
    @day_one = Date.new(2026, 3, 2)
    @day_two = Date.new(2026, 3, 3)
  end

  # The textbook case, worked by hand:
  #
  #   sub-period 1: 1,000 grows to 1,100                  -> 1.10
  #   1,000 is then deposited, so 1,100 becomes 2,100
  #   sub-period 2: 2,100 grows to 2,310                  -> 1.10
  #   chained: 1.10 x 1.10 - 1                            = 21.0%
  #
  # The deposit must not appear as performance. A method that let it through
  # would report 131% for a portfolio that returned 21%.
  test "twr matches the hand computed textbook case" do
    build_textbook_case

    assert_in_delta 0.21, performance.twr.to_f, 0.000001
  end

  # Two days of history annualised is a number with no meaning:
  # a 21% fortnight compounds to something absurd, and printing it would be
  # presenting an artefact of the arithmetic as a fact about the portfolio.
  #
  # The rule covers BOTH annualised figures, so both are asserted here. The
  # period figures are asserted present in the same breath: a short period
  # withholds the annualisation, never the return.
  test "annualized twr and mwr are nil for periods under a year" do
    build_textbook_case
    deposit account: @account, date: @day_one, amount: 1_000

    result = performance

    assert_not_nil result.twr
    assert_nil result.annualized_twr
    assert_not_nil result.mwr, "the period figure is reported, only its annualisation is withheld"
    assert_nil result.annualized_mwr
  end

  # Daily returns of +10%, -10%, 0 have a sample standard deviation
  # of 0.1 exactly (mean 0, variance (0.01 + 0.01 + 0) / 2). Annualising a
  # CALENDAR-daily series uses sqrt(365), not the trading-day sqrt(252): the
  # balance rows include weekends, so a third of the series is structural zeros
  # and the trading-day convention would overstate the result by about 19%.
  test "volatility annualises calendar daily returns by sqrt 365" do
    day_three = @day_two + 1.day
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
    lay_balance account: @account, date: @day_two, opening: 1_100, closing: 990, market_flow: -110
    lay_balance account: @account, date: day_three, opening: 990, closing: 990

    result = performance(end_date: day_three)

    expected = 0.1 * Math.sqrt(365)
    assert_in_delta expected, result.volatility.to_f, 0.0001
    refute_in_delta 0.1 * Math.sqrt(252), result.volatility.to_f, 0.01,
                    "the trading-day convention does not fit a calendar-daily series"
  end

  # Same portfolio, two questions. TWR asks how the holdings did;
  # MWR asks how the investor did, and rewards or punishes the timing of their
  # own contributions. Averaging or substituting one for the other is the error
  # this row exists to prevent.
  test "mwr differs from twr when flows are unevenly timed" do
    start_date = Date.new(2026, 1, 1)
    mid_date = Date.new(2026, 7, 2)
    end_date = Date.new(2026, 12, 31)

    lay_balance account: @account, date: start_date, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: mid_date, opening: 1_000, closing: 2_000, cash_flow: 1_000
    lay_balance account: @account, date: end_date, opening: 2_000, closing: 2_200, market_flow: 200
    deposit account: @account, date: mid_date, amount: 1_000

    result = performance(start_date: start_date, end_date: end_date)

    # All of the growth lands in the final sub-period: 2,000 -> 2,200.
    assert_in_delta 0.10, result.twr.to_f, 0.000001

    # The investor had 1,000 committed for the year and 1,000 for half of it,
    # so the same 200 of gain is earned on less capital: about 13.5%.
    assert_in_delta 0.1346, result.mwr.to_f, 0.002
    refute_equal result.twr, result.mwr
  end

  # This is the defect the issue's proposed cache key would have
  # shipped. `entries_cache_version` counts entries and their timestamps; a
  # daily price sync rewrites holdings and balances and touches no entry, so a
  # figure cached on it stays stale until the user happens to edit a
  # transaction.
  test "cache key changes when a price sync completes without touching entries" do
    build_textbook_case

    before_key = performance.cache_key
    before_entries_version = @family.entries_cache_version

    @family.update!(latest_sync_completed_at: 1.hour.from_now)
    @family.reload

    assert_equal before_entries_version, @family.entries_cache_version,
                 "the fixture must not touch entries, or this proves nothing"
    refute_equal before_key, Portfolio::Performance.new(
      family: @family, account_ids: [ @account.id ],
      period: Period.custom(start_date: @day_one, end_date: @day_two)
    ).cache_key
  end

  test "annualized twr is reported for a period of a year or more" do
    start_date = Date.new(2026, 1, 1)
    end_date = Date.new(2026, 12, 31)

    lay_balance account: @account, date: start_date, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: end_date, opening: 1_000, closing: 1_100, market_flow: 100

    result = performance(start_date: start_date, end_date: end_date)

    assert_in_delta 0.10, result.twr.to_f, 0.000001
    assert_in_delta 0.10, result.annualized_twr.to_f, 0.001,
                    "a 10% year annualises to 10%"
  end

  test "max drawdown measures the largest peak to trough fall" do
    day_three = @day_two + 1.day
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_200, market_flow: 200
    lay_balance account: @account, date: @day_two, opening: 1_200, closing: 900, market_flow: -300
    lay_balance account: @account, date: day_three, opening: 900, closing: 1_000, market_flow: 100

    result = performance(end_date: day_three)

    # The index peaks at 1.20 and falls to 0.90: a 25% drawdown.
    assert_in_delta 0.25, result.max_drawdown.to_f, 0.000001
  end

  # The name matters: the series is rebased ON a base of 100, and its first point
  # is the level AFTER the first return. There is no 100 in the output, which is
  # why the assertions below start at 110.
  test "the index series is rebased on a base of one hundred and starts after the first return" do
    build_textbook_case

    series = performance.index_series

    assert_equal 2, series.size
    assert_in_delta 110.0, series.first.last.to_f, 0.000001
    assert_in_delta 121.0, series.last.last.to_f, 0.000001
    refute_in_delta 100.0, series.first.last.to_f, 0.000001,
                    "the base itself is not a point in the series"
  end

  # A missing rate carried through to the metric surface: a figure that could not be
  # converted is withheld, not approximated.
  test "every ratio is withheld when an exchange rate is missing" do
    eur = create_portfolio_account(family: @family, currency: "EUR")
    lay_balance account: eur, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: eur, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100

    result = performance(account_ids: [ eur.id ])

    assert result.rate_missing?
    assert_nil result.twr
    assert_nil result.mwr
    assert_nil result.volatility
    assert_nil result.max_drawdown
    assert_empty result.index_series
  end

  # Regression: the key was built from family, user, accounts and period only,
  # so two instances whose rows genuinely differ shared one cache entry and
  # whichever ran first decided what both saw.
  test "cache key distinguishes different account cut off dates" do
    build_textbook_case
    period = Period.custom(start_date: @day_one, end_date: @day_two)

    without_cutoff = Portfolio::Performance.new(
      family: @family, account_ids: [ @account.id ], period: period
    )
    with_cutoff = Portfolio::Performance.new(
      family: @family, account_ids: [ @account.id ], period: period,
      active_until_dates: { @account.id => @day_one }
    )

    refute_equal without_cutoff.daily_returns.rows.last.value_close,
                 with_cutoff.daily_returns.rows.last.value_close,
                 "the fixture must produce different data, or this proves nothing"
    refute_equal without_cutoff.cache_key, with_cutoff.cache_key
  end

  # Every figure is converted into the family's currency, but
  # Family#build_cache_key keys on the family id, the latest sync and the
  # accounts' updated_at -- not the currency. Changing the family currency
  # therefore left the old key in place and served figures converted into the
  # previous currency until an unrelated sync changed it.
  test "cache key changes when the family currency changes" do
    build_textbook_case
    before_key = performance.cache_key

    @family.update!(currency: "EUR")

    refute_equal before_key, Portfolio::Performance.new(
      family: @family, account_ids: [ @account.id ],
      period: Period.custom(start_date: @day_one, end_date: @day_two)
    ).cache_key, "figures converted into USD must not be served to an EUR family"
  end

  # The flow scope is the accounts themselves (see Portfolio::DailyReturns),
  # so there is no second set to pass, and none to key the cache on.
  test "the flow scope cannot be widened beyond the accounts measured" do
    assert_raises(ArgumentError) do
      Portfolio::Performance.new(
        family: @family, account_ids: [ @account.id ],
        period: Period.custom(start_date: @day_one, end_date: @day_two),
        scope_account_ids: [ @account.id, create_portfolio_account(family: @family).id ]
      )
    end
  end

  test "an empty scope reports nothing rather than raising" do
    result = performance(account_ids: [])

    refute result.any?
    assert_nil result.twr
  end

  # Eligibility at the scope level. The account's value moved by revaluation only, so
  # nothing records what was paid in. Over a year an XIRR of its opening and
  # closing values solves to 20%, a figure the records do not support.
  test "mwr is withheld when an account in the scope is valuation tracked" do
    start_date = Date.new(2026, 1, 1)
    end_date = Date.new(2026, 12, 31)
    lay_balance account: @account, date: start_date, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: end_date, opening: 1_000, closing: 1_200, revaluation: 200

    result = performance(start_date: start_date, end_date: end_date)

    assert_in_delta 0.20, result.twr.to_f, 0.000001, "the value return is still reportable"
    assert_nil result.mwr
  end

  # The rule must not overreach: an account with no balances in the period
  # contributes nothing, so it cannot make the scope's flows unknown.
  test "an account with no balances in the period does not withhold mwr" do
    start_date = Date.new(2026, 1, 1)
    mid_date = Date.new(2026, 7, 2)
    end_date = Date.new(2026, 12, 31)
    lay_balance account: @account, date: start_date, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: mid_date, opening: 1_000, closing: 2_000, cash_flow: 1_000
    lay_balance account: @account, date: end_date, opening: 2_000, closing: 2_200, market_flow: 200
    deposit account: @account, date: mid_date, amount: 1_000
    empty = create_portfolio_account(family: @family)

    result = performance(account_ids: [ @account.id, empty.id ], start_date: start_date, end_date: end_date)

    assert_in_delta 0.1346, result.mwr.to_f, 0.002
  end

  # A single day: the opening and closing values fall on the same date, so no
  # time passes and no annual rate exists. Newton would otherwise return its
  # 10% starting guess as the answer.
  test "a one day period has no money weighted return" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    buy_trade account: @account, date: @day_one, qty: 1, price: 10

    result = performance(start_date: @day_one, end_date: @day_one)

    assert_nil result.mwr
  end

  # Regression. DailyReturns compacts active_until_dates, so `{ id => nil }` is
  # valid input meaning "no cut-off". The cache key read the RAW hash and called
  # nil.to_date on it, raising NoMethodError before any metric was computed --
  # and a cache key is on the path of every figure, so nothing would have worked.
  test "a nil cut off date is a key, not a crash" do
    period = Period.custom(start_date: @day_one, end_date: @day_two)

    nil_cutoff = Portfolio::Performance.new(
      family: @family, account_ids: [ @account.id ], period: period,
      active_until_dates: { @account.id => nil }
    )
    none = Portfolio::Performance.new(family: @family, account_ids: [ @account.id ], period: period)

    assert_equal none.cache_key, nil_cutoff.cache_key,
                 "a nil cut-off means no cut-off, so it is the same scope and may share an entry"
  end

  # Composition flows at the metric surface. Both accounts are trade-tracked, so the
  # money-weighted return is supported. The flat account holds 1,000 throughout;
  # Arriving appears on day two holding 500. Nothing gained or lost value, so
  # both returns are zero. Reading the arrival as return reported a 50% TWR and
  # an MWR near 1e15.
  test "twr and mwr of a flat portfolio stay zero when an account arrives" do
    day_three = @day_two + 1.day
    arriving = create_portfolio_account(family: @family)
    buy_trade account: @account, date: @day_one - 30, qty: 1, price: 1
    buy_trade account: arriving, date: @day_one - 30, qty: 1, price: 1
    [ @day_one, @day_two, day_three ].each { |date| lay_balance account: @account, date: date, opening: 1_000, closing: 1_000 }
    [ @day_two, day_three ].each { |date| lay_balance account: arriving, date: date, opening: 500, closing: 500 }

    result = performance(account_ids: [ @account.id, arriving.id ], end_date: day_three)

    assert_in_delta 0.0, result.twr.to_f, 0.000001, "money arriving in the scope is not a return"
    assert_not_nil result.mwr, "both accounts are trade-tracked, so the figure is supported"
    assert_in_delta 0.0, result.mwr.to_f, 0.000001
  end

  # The flat account holds 1,000; Leaving holds 10 and is
  # cut off after day two. Nothing gained or lost value. Treating the departure
  # as an investor loss reported an MWR of about -84% over three days.
  test "twr and mwr of a flat portfolio stay zero when an account leaves" do
    day_three = @day_two + 1.day
    leaving = create_portfolio_account(family: @family)
    buy_trade account: @account, date: @day_one - 30, qty: 1, price: 1
    buy_trade account: leaving, date: @day_one - 30, qty: 1, price: 1
    [ @day_one, @day_two, day_three ].each { |date| lay_balance account: @account, date: date, opening: 1_000, closing: 1_000 }
    [ @day_one, @day_two ].each { |date| lay_balance account: leaving, date: date, opening: 10, closing: 10 }

    result = Portfolio::Performance.new(
      family: @family, account_ids: [ @account.id, leaving.id ],
      period: Period.custom(start_date: @day_one, end_date: day_three),
      active_until_dates: { leaving.id => @day_two }
    )

    assert_in_delta 0.0, result.twr.to_f, 0.000001
    assert_not_nil result.mwr, "both accounts are trade-tracked, so the figure is supported"
    assert_in_delta 0.0, result.mwr.to_f, 0.000001, "money leaving the scope is not an investor loss"
  end

  # An account with one day
  # of balance history supports no return method. Performance applies that to
  # the whole scope, as it already does for MWR: one such account withholds
  # every time-weighted figure.
  test "time weighted figures are withheld when an account in the scope has one balance day" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100

    result = performance

    assert_nil result.twr, "a single balance day supports no return (was 10%)"
    assert_nil result.annualized_twr
    assert_nil result.volatility
    assert_nil result.max_drawdown
    assert_empty result.index_series
  end

  test "time weighted figures are withheld when one account among several has one balance day" do
    one_row = create_portfolio_account(family: @family)
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_010, market_flow: 10
    lay_balance account: one_row, date: @day_two, opening: 500, closing: 550, market_flow: 50

    result = performance(account_ids: [ @account.id, one_row.id ])

    assert_nil result.twr, "one unsupported account withholds the aggregate (was 56%)"
    assert_nil result.volatility
    assert_empty result.index_series
  end

  # Eligibility reads the same window DailyReturns does. The account has two
  # balance days in the period, but its cut-off is the first, so the series
  # holds one day of it and that supports no return. Counted over the whole
  # period, it passed and the chained zero of its departure day was quoted.
  test "a cut-off that leaves one in-window balance day withholds time weighted figures" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_010, market_flow: 10

    uncut = performance
    cut = Portfolio::Performance.new(
      family: @family, account_ids: [ @account.id ],
      period: Period.custom(start_date: @day_one, end_date: @day_two),
      active_until_dates: { @account.id => @day_one }
    )

    assert_in_delta 0.01, uncut.twr.to_f, 0.000001, "without the cut-off the account supports a return"
    assert_nil cut.twr, "one day in the window supports none"
    assert_empty cut.index_series
  end

  # The rule must not overreach, mirroring the MWR carve-out: an account with no
  # balance rows in the period contributes nothing and cannot make the figure
  # unsupported.
  test "an account with no balance rows in the period does not withhold time weighted figures" do
    empty = create_portfolio_account(family: @family)
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_010, market_flow: 10

    result = performance(account_ids: [ @account.id, empty.id ])

    assert_in_delta 0.01, result.twr.to_f, 0.000001
  end

  # No annualisation below a year, applied to the money-weighted return. The
  # same flows read annually give 603.36 -- 60,336% -- for a gain of a few
  # percent over two days, which is an extrapolation of the
  # period, not a figure the assets earned. GIPS is explicit that a return for a
  # period under a year must not be annualised. The deposit is dated before the
  # period so the account is trade-tracked without adding an in-period flow.
  test "the money weighted return is the return over the period, not annualised" do
    lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: @day_two, opening: 1_000, closing: 1_035.7143, market_flow: 35.7143
    deposit account: @account, date: @day_one - 10.days, amount: 1_000

    result = performance

    assert_in_delta 0.035714, result.mwr.to_f, 0.00001,
                    "the figure is the 3.5714% the period returned, not its annualisation"
    assert_nil result.annualized_mwr,
               "a period under a year has no annualised money-weighted return"
  end

  # The triage plan named this case for the `growth <= 0` guard in #annualize.
  # It is reached, but only on the time-weighted side, and the difference is
  # worth writing down rather than asserting a shared nil and moving on:
  #
  #   twr  -> -1 exactly, so growth is 0 and the root of it is not a return;
  #           the guard fires.
  #   mwr  -> nil before annualisation is even reached. A total loss leaves no
  #           terminal value, so the flow series never changes sign and XIRR
  #           has nothing to solve. The `chained.nil?` branch answers first.
  #
  # So the guard is unreachable through the money-weighted path, and a test
  # claiming otherwise would be asserting a mechanism that does not run.
  test "a total loss has no annualised return on either side, for two different reasons" do
    start_date = Date.new(2026, 1, 1)
    end_date = Date.new(2026, 12, 31)

    lay_balance account: @account, date: start_date, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: end_date, opening: 1_000, closing: 0, market_flow: -1_000
    deposit account: @account, date: start_date + 5, amount: 1

    result = performance(start_date: start_date, end_date: end_date)

    assert_equal BigDecimal(-1), result.twr, "everything was lost"
    assert_nil result.annualized_twr, "growth is zero, and its root is not a return"
    assert_nil result.mwr, "no terminal value means no sign change for XIRR to solve"
    assert_nil result.annualized_mwr
  end

  # The money-weighted figure is "the return over the period", and for capital present throughout it
  # is. For capital that arrives mid-period it is not the holding-period figure,
  # and the gap is large enough that a reader has to be told.
  #
  # The rate is solved per unit of the period's OWN span, so money at work for
  # half the period is discounted over half a unit: 10% over half a unit
  # compounds to (1.10)^2 - 1 = 21% per unit. The time-weighted figure reports
  # the 10% the assets earned. Neither is wrong; they answer different
  # questions, and this pins the difference so the choice cannot drift silently.
  test "money weighted extrapolates capital that arrives mid period, and time weighted does not" do
    start_date = Date.new(2026, 1, 1)
    arrival = Date.new(2026, 7, 2)
    end_date = Date.new(2026, 12, 31)

    lay_balance account: @account, date: start_date, opening: 0, closing: 0
    lay_balance account: @account, date: arrival, opening: 0, closing: 1_000, cash_flow: 1_000
    lay_balance account: @account, date: end_date, opening: 1_000, closing: 1_100, market_flow: 100
    deposit account: @account, date: arrival, amount: 1_000

    result = performance(start_date: start_date, end_date: end_date)

    assert_in_delta 0.10, result.twr.to_f, 0.000001,
                    "the assets earned 10%, and that is the holding-period figure"
    assert_in_delta 0.21, result.mwr.to_f, 0.005,
                    "an IRR per unit time extrapolates the idle half of the period"
    assert_operator result.mwr.to_f, :>, result.twr.to_f,
                    "if these ever converge the solver stopped solving per unit span"
  end

  # The other side of the boundary: at a year or more the annualised figure is
  # reported, and it is exactly the annual rate the same flows produce.
  #
  # The tolerance on mwr is tight on purpose. The closing value is dated at the
  # end of the last row's day, so a 365-day period spans 365 days and the rate
  # is the annual one: 0.13462698. Dated at the last row's own date instead the
  # series spans 364 days and the rate is 0.13475242 -- 1.25e-4 out, which this
  # delta rejects and a loose one would wave through.
  test "the annualised money weighted return is reported at a year or more" do
    start_date = Date.new(2026, 1, 1)
    mid_date = Date.new(2026, 7, 2)
    end_date = Date.new(2026, 12, 31)

    lay_balance account: @account, date: start_date, opening: 1_000, closing: 1_000
    lay_balance account: @account, date: mid_date, opening: 1_000, closing: 2_000, cash_flow: 1_000
    lay_balance account: @account, date: end_date, opening: 2_000, closing: 2_200, market_flow: 200
    deposit account: @account, date: mid_date, amount: 1_000

    result = performance(start_date: start_date, end_date: end_date)

    assert_in_delta 0.13462698, result.mwr.to_f, 0.000001,
                    "a 365-day period spans 365 days, so the period rate is the annual rate"

    assert_not_nil result.annualized_mwr, "365 days reaches MIN_DAYS_FOR_ANNUALISATION"
    assert_in_delta result.mwr.to_f, result.annualized_mwr.to_f, 1e-9,
                    "annualising a rate already measured over a year returns it unchanged"
  end

  # Eligibility used to cost up to four queries per account, and both supported?
  # methods paid it separately on the same uncached path. The property is that
  # the count does not grow with the account count, so that is what is asserted
  # rather than a number I have to keep in my head: three resolution queries
  # plus the Account load the call site has always done.
  test "eligibility for many accounts is resolved in a fixed number of queries" do
    few = performance(account_ids: 2.times.map { build_valuation_tracked_account }.map(&:id))
    many = performance(account_ids: 6.times.map { build_valuation_tracked_account }.map(&:id))

    few_queries = capture_sql_queries { few.send(:return_scopes) }
    many_queries = capture_sql_queries { many.send(:return_scopes) }

    assert_equal few_queries.size, many_queries.size,
                 "resolution must not grow with the account count: 2 accounts took " \
                 "#{few_queries.size}, 6 took #{many_queries.size}"
    assert_operator many_queries.size, :<=, 4,
                    "expected the account load plus three resolution queries, got #{many_queries.size}"
  end

  # The second call site. It reads only balance_days, so it cost 1 + N rather
  # than 1 + 4N, and it now shares the resolution with money_weighted_supported?.
  test "both supported checks share one eligibility resolution" do
    accounts = 3.times.map { build_valuation_tracked_account }
    subject = performance(account_ids: accounts.map(&:id))

    first = capture_sql_queries { subject.send(:time_weighted_supported?) }
    # The other call site, not the same one twice: this is what proves the two
    # share a resolution rather than each memoising its own.
    shared = ActiveRecord::Base.uncached do
      capture_sql_queries { subject.send(:money_weighted_supported?, [ :row, :row ]) }
    end

    assert_operator first.size, :<=, 4
    assert_empty shared,
                 "money_weighted_supported? reads the resolution time_weighted_supported? already paid for"
  end

  private
    # 1,000 EUR, then a 10 EUR fee: closing values 1,000 and 990, so the mean is
    # 995 and the ratio 10 / 995. No exchange rate is stored.
    def eur_account_with_fee
      eur = create_portfolio_account(family: @family, currency: "EUR")
      fee_entry account: eur, date: @day_two, amount: 10
      lay_balance account: eur, date: @day_one, opening: 1_000, closing: 1_000
      lay_balance account: eur, date: @day_two, opening: 1_000, closing: 990, cash_flow: -10
      eur
    end

    def build_valuation_tracked_account
      account = create_portfolio_account(family: @family)
      lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
      lay_balance account: account, date: @day_two, opening: 1_000, closing: 1_100, market_flow: 100
      account
    end

    def build_textbook_case
      lay_balance account: @account, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
      lay_balance account: @account, date: @day_two, opening: 1_100, closing: 2_310,
                  cash_flow: 1_000, market_flow: 210
      deposit account: @account, date: @day_two, amount: 1_000
    end

    def performance(account_ids: [ @account.id ], start_date: @day_one, end_date: @day_two)
      Portfolio::Performance.new(
        family: @family,
        account_ids: account_ids,
        period: Period.custom(start_date: start_date, end_date: end_date)
      )
    end
end
