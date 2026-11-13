require "test_helper"

class InvestmentStatementTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    # families(:empty) defaults to currency "USD"
    @statement = InvestmentStatement.new(@family, user: nil)
  end

  test "portfolio_value and cash_balance with a single-currency family" do
    create_investment_account(balance: 1000, cash_balance: 100)

    assert_equal 1000, @statement.portfolio_value
    assert_equal 100, @statement.cash_balance
    assert_equal 900, @statement.holdings_value
  end

  test "portfolio_value converts foreign-currency accounts to family currency" do
    create_investment_account(balance: 1921.92, cash_balance: -162, currency: "USD")
    create_investment_account(balance: 1000, cash_balance: 1000, currency: "EUR")

    ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      date: Date.current,
      rate: 1.1
    )

    # 1921.92 + 1000 * 1.1 = 3021.92
    assert_in_delta 3021.92, @statement.portfolio_value, 0.001
    # -162 + 1000 * 1.1 = 938
    assert_in_delta 938, @statement.cash_balance, 0.001
    # 3021.92 - 938 = 2083.92
    assert_in_delta 2083.92, @statement.holdings_value, 0.001
  end

  test "portfolio_value falls back to 1:1 when FX rate is missing" do
    create_investment_account(balance: 1921.92, currency: "USD")
    create_investment_account(balance: 1000, currency: "EUR")

    # No ExchangeRate row → rates_for defaults to 1
    assert_in_delta 2921.92, @statement.portfolio_value, 0.001
  end

  test "current_holdings includes holdings from every investment account regardless of currency" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD"
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR"
    )

    assert_equal 2, @statement.current_holdings.count
  end

  test "top_holdings ranks by family-currency value across currencies" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD"
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR"
    )

    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "USD",
      date: Date.current, rate: 1.1
    )

    # 2000 EUR = 2200 USD > 2100 USD, so ASML outranks AAPL in family currency
    top = @statement.top_holdings(limit: 2)
    assert_equal %w[ASML AAPL], top.map(&:ticker)
  end

  test "top_holdings rolls up the same security across accounts" do
    ira = create_investment_account(balance: 5000, cash_balance: 0, currency: "USD")
    taxable = create_investment_account(balance: 3000, cash_balance: 0, currency: "USD")
    other = create_investment_account(balance: 2000, cash_balance: 0, currency: "USD")

    aapl = Security.create!(ticker: "AAPL", name: "Apple")
    msft = Security.create!(ticker: "MSFT", name: "Microsoft")

    Holding.create!(
      account: ira, security: aapl, date: Date.current,
      qty: 10, price: 200, amount: 2000, currency: "USD"
    )
    Holding.create!(
      account: taxable, security: aapl, date: Date.current,
      qty: 15, price: 200, amount: 3000, currency: "USD"
    )
    Holding.create!(
      account: other, security: msft, date: Date.current,
      qty: 10, price: 200, amount: 2000, currency: "USD"
    )

    top = @statement.top_holdings(limit: 5)

    assert_equal %w[AAPL MSFT], top.map(&:ticker)
    assert_equal 1, top.count { |row| row.ticker == "AAPL" }
    assert_equal Money.new(5000, "USD"), top.first.amount_money
    # Portfolio total = 5000 + 3000 + 2000 = 10000; AAPL = 50%, MSFT = 20%
    assert_in_delta 50.0, top.first.weight, 0.01
    assert_in_delta 20.0, top.second.weight, 0.01
  end

  test "top_holdings weight is percent of total portfolio including cash" do
    account = create_investment_account(balance: 10_000, cash_balance: 4000, currency: "USD")
    security = Security.create!(ticker: "VOO", name: "Vanguard S&P 500")

    Holding.create!(
      account: account, security: security, date: Date.current,
      qty: 30, price: 200, amount: 6000, currency: "USD"
    )

    top = @statement.top_holdings(limit: 1)

    assert_equal 1, top.size
    # 6000 / 10000 portfolio = 60% (not 100% of holdings)
    assert_in_delta 60.0, top.first.weight, 0.01
  end

  test "top_holdings still lists positions when portfolio_value is stale zero" do
    # Cached Account#balance can lag behind Holding rows; presence must not
    # depend on portfolio_value alone.
    account = create_investment_account(balance: 0, cash_balance: 0, currency: "USD")
    security = Security.create!(ticker: "AAPL", name: "Apple")

    Holding.create!(
      account: account, security: security, date: Date.current,
      qty: 10, price: 200, amount: 2000, currency: "USD"
    )

    assert_equal 0, @statement.portfolio_value

    top = @statement.top_holdings(limit: 5)

    assert_equal 1, top.size
    assert_equal "AAPL", top.first.ticker
    assert_equal Money.new(2000, "USD"), top.first.amount_money
    # Falls back to holdings total as weight denominator when portfolio is 0
    assert_in_delta 100.0, top.first.weight, 0.01
  end

  test "top_holdings weight stays within 100 when cash is negative" do
    # Margin or an unsettled buy: balance 960 = holdings 1000 + cash -40.
    account = create_investment_account(balance: 960, cash_balance: -40, currency: "USD")
    security = Security.create!(ticker: "VTI", name: "Vanguard Total Market")

    Holding.create!(
      account: account, security: security, date: Date.current,
      qty: 5, price: 200, amount: 1000, currency: "USD"
    )

    top = @statement.top_holdings(limit: 1)

    assert_equal 1, top.size
    assert_in_delta 100.0, top.first.weight, 0.01
  end

  test "top_holdings ignores a negative holding row when weighting" do
    # Holding validates amount >= 0, but Holding::Materializer writes via
    # upsert_all, which skips validations — an over-sell can land a negative row.
    account = create_investment_account(balance: 500, cash_balance: 0, currency: "USD")
    good = Security.create!(ticker: "AAPL", name: "Apple")
    bad = Security.create!(ticker: "MSFT", name: "Microsoft")

    Holding.create!(
      account: account, security: good, date: Date.current,
      qty: 5, price: 200, amount: 1000, currency: "USD"
    )

    negative = Holding.new(
      account: account, security: bad, date: Date.current,
      qty: 2, price: 250, amount: -500, currency: "USD"
    )
    negative.save!(validate: false)

    top = @statement.top_holdings(limit: 5)

    assert_equal [ "AAPL" ], top.map(&:ticker)
    assert_in_delta 100.0, top.first.weight, 0.01
  end

  test "top_holdings ignores a negative row sharing a security with a good one" do
    # current_holdings is DISTINCT ON (account_id, security_id), so one security
    # held in two accounts yields two rows. A negative row in one account must
    # not net against the good row in the other before the value is taken.
    ira = create_investment_account(balance: 1000, cash_balance: 0, currency: "USD")
    taxable = create_investment_account(balance: 0, cash_balance: 0, currency: "USD")
    security = Security.create!(ticker: "AAPL", name: "Apple")

    Holding.create!(
      account: ira, security: security, date: Date.current,
      qty: 5, price: 200, amount: 1000, currency: "USD"
    )

    negative = Holding.new(
      account: taxable, security: security, date: Date.current,
      qty: 2, price: 250, amount: -500, currency: "USD"
    )
    negative.save!(validate: false)

    # Trades give both rows a cost basis, so combined_holding_trend actually has
    # something to combine — without them Holding#trend is nil and the trend
    # half of the filtering would go unexercised.
    create_trade_for(account: ira, security: security, qty: 5, price: 200)
    create_trade_for(account: taxable, security: security, qty: 2, price: 250)

    top = @statement.top_holdings(limit: 5)

    assert_equal [ "AAPL" ], top.map(&:ticker)
    assert_equal Money.new(1000, "USD"), top.first.amount_money
    assert_in_delta 100.0, top.first.weight, 0.01

    # The bad row must not reach the trend either: netting it in would give
    # current 500 (1000 + -500) against previous 1500.
    assert_equal Money.new(1000, "USD"), top.first.trend.current
    assert_equal Money.new(1000, "USD"), top.first.trend.previous
  end

  test "top_holdings computes trends only for the selected limit" do
    large = create_investment_account(balance: 5000, cash_balance: 0)
    small = create_investment_account(balance: 1000, cash_balance: 0)

    top_security = Security.create!(ticker: "TOP1", name: "Top One")
    skipped_security = Security.create!(ticker: "SKIP", name: "Skipped")

    Holding.create!(
      account: large, security: top_security, date: Date.current,
      qty: 50, price: 100, amount: 5000, currency: "USD",
      cost_basis: 90, cost_basis_locked: true
    )
    Holding.create!(
      account: small, security: skipped_security, date: Date.current,
      qty: 10, price: 100, amount: 1000, currency: "USD",
      cost_basis: 90, cost_basis_locked: true
    )

    # Only the one holding in the selected top security should ask for a trend
    Holding.any_instance.expects(:trend).once.returns(nil)

    top = @statement.top_holdings(limit: 1)

    assert_equal %w[TOP1], top.map(&:ticker)
  end

  # allocation shares top_holdings' denominator, so its weights sum to the
  # invested share of the portfolio and cash is the visible residual.
  test "allocation rolls up duplicate securities and weights leave cash as the residual" do
    # Coherent balances: each account's balance is its holdings plus its cash,
    # so the weight residual is genuinely cash and not stale balance data.
    ira = create_investment_account(balance: 3000, cash_balance: 0, currency: "USD")
    taxable = create_investment_account(balance: 2000, cash_balance: 1500, currency: "USD")

    aapl = Security.create!(ticker: "AAPL", name: "Apple")
    msft = Security.create!(ticker: "MSFT", name: "Microsoft")

    Holding.create!(
      account: ira, security: aapl, date: Date.current,
      qty: 10, price: 100, amount: 1000, currency: "USD"
    )
    Holding.create!(
      account: taxable, security: aapl, date: Date.current,
      qty: 5, price: 100, amount: 500, currency: "USD"
    )
    Holding.create!(
      account: ira, security: msft, date: Date.current,
      qty: 20, price: 100, amount: 2000, currency: "USD"
    )

    allocation = @statement.allocation

    assert_equal 2, allocation.size
    assert_equal %w[MSFT AAPL], allocation.map(&:ticker)
    assert_equal Money.new(1500, "USD"), allocation.find { |a| a.ticker == "AAPL" }.amount

    # 3500 of holdings against a 5000 portfolio: 70% invested, 30% cash.
    assert_in_delta 70.0, allocation.sum(&:weight), 0.01

    cash_share = @statement.cash_balance / @statement.portfolio_value * 100
    assert_in_delta 100.0, allocation.sum(&:weight) + cash_share, 0.01
  end

  # The latent bug behind the divergence: the two methods used different
  # denominators, so one security could report two percentages. Nothing renders
  # allocation today, so this guards whoever wires it up.
  test "top_holdings and allocation report the same weight for a security" do
    account = create_investment_account(balance: 10_000, cash_balance: 4000, currency: "USD")
    security = Security.create!(ticker: "VOO", name: "Vanguard S&P 500")

    Holding.create!(
      account: account, security: security, date: Date.current,
      qty: 30, price: 200, amount: 6000, currency: "USD"
    )

    top_weight = @statement.top_holdings(limit: 1).first.weight
    allocation_weight = @statement.allocation.find { |a| a.ticker == "VOO" }.weight

    assert_in_delta top_weight, allocation_weight, 0.01
    assert_in_delta 60.0, top_weight, 0.01
  end

  test "allocation weights sum to 100% with mixed currencies" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD"
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR"
    )

    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "USD",
      date: Date.current, rate: 1.1
    )

    allocation = @statement.allocation
    assert_equal 2, allocation.size
    assert_in_delta 100.0, allocation.sum(&:weight), 0.01
    # Every row is labeled in family currency
    assert allocation.all? { |a| a.amount.currency.iso_code == "USD" }
  end

  test "unrealized_gains sums in family currency with mixed-currency holdings" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD",
      cost_basis: 200, cost_basis_locked: true
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR",
      cost_basis: 450, cost_basis_locked: true
    )

    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "USD",
      date: Date.current, rate: 1.1
    )

    # AAPL unrealized = 2100 - (10 * 200) = 100 USD
    # ASML unrealized = 2000 - (4 * 450) = 200 EUR → 220 USD @ 1.1
    # Total = 320 USD
    assert_in_delta 320, @statement.unrealized_gains, 0.001
    assert_equal "USD", @statement.unrealized_gains_money.currency.iso_code
  end

  test "unrealized_gains_trend is denominated in family currency" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD",
      cost_basis: 200, cost_basis_locked: true
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR",
      cost_basis: 450, cost_basis_locked: true
    )

    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "USD",
      date: Date.current, rate: 1.1
    )

    trend = @statement.unrealized_gains_trend
    assert_equal "USD", trend.current.currency.iso_code
    assert_equal "USD", trend.previous.currency.iso_code
    # current = 2100 USD + (2000 EUR * 1.1) = 4300 USD
    assert_in_delta 4300, trend.current.amount, 0.001
    # previous (cost basis) = (10 * 200) USD + (4 * 450 * 1.1) EUR→USD = 2000 + 1980 = 3980 USD
    assert_in_delta 3980, trend.previous.amount, 0.001
  end

  test "period_return_trend returns nil when no balance data in period" do
    period = Period.custom(start_date: 10.years.ago.to_date, end_date: 9.years.ago.to_date)
    assert_nil @statement.period_return_trend(period: period)
  end

  test "period_return_trend returns nil when start portfolio value is zero" do
    account = create_investment_account(balance: 5000)
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current)
    # Balance only inside the period — nothing strictly before period_start means start_value = 0
    account.balances.create!(
      date: period.date_range.begin,
      balance: 5000,
      currency: @family.currency,
      net_market_flows: 200
    )
    assert_nil @statement.period_return_trend(period: period)
  end

  test "period_return_trend returns Trend with correct absolute and percent return" do
    account = create_investment_account(balance: 10_500)
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current)

    # Pre-period row: start_non_cash_balance drives end_balance (virtual stored column)
    account.balances.create!(
      date: period.date_range.begin - 1.day,
      balance: 10_000,
      currency: @family.currency,
      start_non_cash_balance: 10_000,
      net_market_flows: 0
    )
    # In-period row: 500 of market gains
    account.balances.create!(
      date: period.date_range.begin,
      balance: 10_500,
      currency: @family.currency,
      start_non_cash_balance: 10_000,
      net_market_flows: 500
    )

    trend = @statement.period_return_trend(period: period)
    assert_not_nil trend
    assert_in_delta 500, trend.value.amount, 1
    assert_in_delta 5.0, trend.percent, 0.1
  end

  test "totals skips cache when there are no investment accounts" do
    Rails.cache.expects(:fetch).never

    totals = @statement.totals(period: Period.current_month)

    assert_equal Money.new(0, "USD"), totals.contributions
    assert_equal Money.new(0, "USD"), totals.withdrawals
    assert_equal Money.new(0, "USD"), totals.dividends
    assert_equal Money.new(0, "USD"), totals.interest
    assert_equal 0, totals.trades_count
  end

  test "totals aggregate directly from trade entries" do
    # Use the full current month: a month-to-date period collapses to a single
    # day on the 1st, which would drop the start_date + 1.day trade below.
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    shared_user = users(:new_email)
    investment_account = create_investment_account(balance: 500)
    hidden_account = create_investment_account(balance: 500)
    investment_account.share_with!(shared_user, permission: "read_only", include_in_finances: true)

    create_trade(account: investment_account, qty: 2, amount: 120, date: period.start_date)
    create_trade(account: investment_account, qty: -1, amount: -40, date: period.start_date + 1.day)
    create_trade(account: investment_account, qty: 1, amount: 999, date: period.start_date - 1.day)
    create_trade(account: hidden_account, qty: 1, amount: 9999, date: period.start_date)

    statement = InvestmentStatement.new(@family, user: shared_user)
    totals = nil
    queries = capture_sql_queries { totals = statement.totals(period: period) }

    assert_equal Money.new(120, "USD"), totals.contributions
    assert_equal Money.new(40, "USD"), totals.withdrawals
    assert_equal 2, totals.trades_count

    aggregate_queries = queries.grep(/SUM\(CASE WHEN trades\.qty > 0/)
    assert_equal 1, aggregate_queries.size
    assert_includes aggregate_queries.first, "FROM entries LEFT JOIN trades"
    assert_includes aggregate_queries.first, "entries.entryable_type = 'Trade'"
    assert_includes aggregate_queries.first, "entries.account_id IN"
    assert_includes aggregate_queries.first, "entries.excluded = false"
    assert_no_match(/FROM \(SELECT "trades"\.\*/, aggregate_queries.first)
    # account_ids is pre-scoped to the family's visible accounts, so the
    # aggregate trusts that input and no longer joins back to accounts.
    assert_no_match(/JOIN accounts/, aggregate_queries.first)
  end

  test "totals aggregate dividend and interest income from income trades" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    create_income_trade(account: account, label: "Dividend", amount: 50, date: period.start_date)
    create_income_trade(account: account, label: "Dividend", amount: 25, date: period.start_date + 1.day)
    create_income_trade(account: account, label: "Interest", amount: 10, date: period.start_date)
    # Outside the period, must not be counted
    create_income_trade(account: account, label: "Dividend", amount: 999, date: period.start_date - 1.day)

    totals = @statement.totals(period: period)

    assert_equal Money.new(75, "USD"), totals.dividends
    assert_equal Money.new(10, "USD"), totals.interest
    assert_equal Money.new(85, "USD"), totals.total_income
  end

  test "income trades are not counted as contributions or withdrawals" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    create_trade(account: account, qty: 2, amount: 120, date: period.start_date)
    create_income_trade(account: account, label: "Dividend", amount: 50, date: period.start_date)

    totals = @statement.totals(period: period)

    # qty: 0 keeps income out of both direction branches
    assert_equal Money.new(120, "USD"), totals.contributions
    assert_equal Money.new(0, "USD"), totals.withdrawals
    assert_equal Money.new(50, "USD"), totals.dividends
  end

  test "a buy relabeled to Dividend is counted as income only, not also as a contribution" do
    # The activity-label quick editor permits changing the label on its own and
    # leaves qty untouched, so an income-labeled trade can carry qty > 0. It must
    # not land in both the direction bucket and the income bucket.
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    trade_entry = create_trade(account: account, qty: 2, amount: 120, date: period.start_date)
    trade_entry.trade.update!(investment_activity_label: "Dividend")

    totals = @statement.totals(period: period)

    assert_equal Money.new(0, "USD"), totals.contributions
    # Income is signed (Portfolio::FlowClassifier): the 120 left the account,
    # so the relabeled row nets against income rather than adding to it.
    assert_equal Money.new(-120, "USD"), totals.dividends
    assert_equal Money.new(-120, "USD"), totals.total_income
  end

  test "a sell relabeled to Interest is counted as income only, not also as a withdrawal" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    trade_entry = create_trade(account: account, qty: -1, amount: -40, date: period.start_date)
    trade_entry.trade.update!(investment_activity_label: "Interest")

    totals = @statement.totals(period: period)

    assert_equal Money.new(0, "USD"), totals.withdrawals
    assert_equal Money.new(40, "USD"), totals.interest
  end

  test "labeled non-income trades still count by direction" do
    # Only Dividend/Interest are excluded from the direction buckets; Buy, Sell
    # and Reinvestment keep their existing contribution/withdrawal treatment.
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    buy = create_trade(account: account, qty: 2, amount: 120, date: period.start_date)
    buy.trade.update!(investment_activity_label: "Buy")
    reinvest = create_trade(account: account, qty: 1, amount: 30, date: period.start_date)
    reinvest.trade.update!(investment_activity_label: "Reinvestment")

    totals = @statement.totals(period: period)

    assert_equal Money.new(150, "USD"), totals.contributions
    # Reinvestment is deliberately not folded into dividend income; doing so
    # would require removing it from contributions too.
    assert_equal Money.new(0, "USD"), totals.dividends
  end

  test "totals convert foreign-currency dividends into family currency" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500, currency: "EUR")

    ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      date: period.start_date,
      rate: 1.1
    )

    create_income_trade(account: account, label: "Dividend", amount: 100, date: period.start_date)

    totals = @statement.totals(period: period)

    assert_equal Money.new(110, "USD"), totals.dividends
  end

  test "total_dividends and total_interest expose all-time income" do
    account = create_investment_account(balance: 500)

    create_income_trade(account: account, label: "Dividend", amount: 40, date: 2.years.ago.to_date)
    create_income_trade(account: account, label: "Interest", amount: 5, date: Date.current)

    assert_equal 40, @statement.total_dividends
    assert_equal 5, @statement.total_interest
  end

  test "dividends and interest count the transaction shapes providers write" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    create_income_trade(account: account, label: "Dividend", amount: 50, date: period.start_date)
    create_income_transaction(account: account, label: "Dividend", amount: 12.5, date: period.start_date, extra_shape: :flat)
    create_income_transaction(account: account, label: "Interest", amount: 4, date: period.start_date, extra_shape: :none)
    # PlaidAccount::Investments::TransactionsProcessor writes a dividend as
    # a qty-0 trade with amount 0 * price, so its cash is not recoverable
    # here (its `price` is a per-share figure, not the payment). It is
    # income with amount 0 until the processor is fixed; the 62.5 below
    # deliberately excludes it.
    create_plaid_dividend_trade(account: account, date: period.start_date)
    # Pending income is not counted until it posts
    create_labelled_transaction(account: account, label: "Dividend", amount: -99, date: period.start_date, extra: { "plaid" => { "pending" => true } })
    # A labelled transaction outside the period is not counted
    create_income_transaction(account: account, label: "Dividend", amount: 999, date: period.start_date - 1.day, extra_shape: :flat)

    totals = @statement.totals(period: period)

    assert_equal Money.new(62.5, "USD"), totals.dividends
    assert_equal Money.new(4, "USD"), totals.interest
    assert_equal Money.new(66.5, "USD"), totals.total_income
    assert_equal Money.new(0, "USD"), totals.contributions
  end

  test "income nets by sign, so a charge or reversal labelled as income reduces it" do
    # Portfolio::FlowClassifier decides income by label, not sign, and says to
    # sum signed amounts: a margin-interest charge labelled "Interest" is money
    # out and must lower interest, not add to it.
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    create_income_trade(account: account, label: "Dividend", amount: 100, date: period.start_date)
    create_income_trade(account: account, label: "Interest", amount: 50, date: period.start_date)
    reversal = create_income_trade(account: account, label: "Dividend", amount: 30, date: period.start_date)
    reversal.update_columns(amount: 30)
    create_labelled_transaction(account: account, label: "Interest", amount: 10, date: period.start_date)

    totals = @statement.totals(period: period)

    assert_equal Money.new(70, "USD"), totals.dividends
    assert_equal Money.new(40, "USD"), totals.interest
    assert_equal Money.new(110, "USD"), totals.total_income
  end

  test "trades_count counts trades, not the income transactions read beside them" do
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)

    create_trade(account: account, qty: 2, amount: 120, date: period.start_date)
    create_income_transaction(account: account, label: "Dividend", amount: 10, date: period.start_date)
    create_income_transaction(account: account, label: "Interest", amount: 3, date: period.start_date)

    totals = @statement.totals(period: period)

    assert_equal Money.new(13, "USD"), totals.total_income
    assert_equal 1, totals.trades_count
  end

  test "contributions and withdrawals count trades only, not external cash transactions" do
    # None of the non-trade entries below is income, so reading labelled
    # transactions for income must not let them move the direction buckets.
    # Totals#contributions is the cash committed to buying securities:
    # counting the 800 deposit and the 1 000 buy it funded would count that
    # money twice.
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    account = create_investment_account(balance: 500)
    checking = @family.accounts.create!(name: "Checking", balance: 5000, currency: "USD", accountable: Depository.new)

    create_portfolio_trade(account: account, qty: 10, price: 100, fee: 0, date: period.start_date)
    create_portfolio_trade(account: account, qty: -2, price: 100, fee: 0, date: period.start_date)
    create_labelled_transaction(account: account, label: "Contribution", amount: -300, date: period.start_date)
    create_labelled_transaction(account: account, label: "Withdrawal", amount: 50, date: period.start_date)
    create_labelled_transaction(account: account, label: nil, kind: "investment_contribution", amount: -200, date: period.start_date)
    create_linked_transfer(family: @family, from: checking, to: account, amount: 800, date: period.start_date)

    totals = @statement.totals(period: period)

    assert_equal Money.new(1000, "USD"), totals.contributions, "only the buy is a contribution"
    assert_equal Money.new(200, "USD"), totals.withdrawals, "only the sale is a withdrawal"
    assert_equal 2, totals.trades_count
  end

  test "current_holdings memoizes so repeated dashboard-style calls issue a single query" do
    account = create_investment_account(balance: 2100, currency: "USD")
    security = Security.create!(ticker: "AAPL", name: "Apple")

    Holding.create!(
      account: account, security: security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD"
    )

    queries = capture_sql_queries do
      @statement.current_holdings
      @statement.top_holdings(limit: 5)
      @statement.allocation
      @statement.day_change
    end

    holdings_queries = queries.grep(/MAX\(provider_holdings\.updated_at::date\)/)
    assert_equal 1, holdings_queries.size,
      "current_holdings should only run its holdings query once per instance, not once per caller"
  end

  test "current_holdings memoizes the empty (no investment accounts) case too" do
    queries = capture_sql_queries do
      @statement.current_holdings
      @statement.current_holdings
    end

    account_queries = queries.grep(/FROM "accounts"/)
    assert_equal 1, account_queries.size,
      "the investment_accounts lookup backing current_holdings should only run once, even for the empty case"
  end

  test "totals cache invalidates when family currency changes" do
    create_investment_account(balance: 500)
    period = Period.last_30_days

    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    dummy_result = { contributions: 0, withdrawals: 0, dividends: 0, interest: 0, trades_count: 0 }
    InvestmentStatement::Totals.expects(:new).twice.returns(stub(call: dummy_result))

    statement = InvestmentStatement.new(@family)
    statement.totals(period: period)

    @family.update!(currency: "EUR")
    InvestmentStatement.new(@family.reload).totals(period: period)
  end

  # Two parcels of one security, materialised the way a sync does: 60 bought on
  # 2024-01-10 at $12 and 40 on 2024-03-05 at $20 (blended $15.20), then 40 sold
  # on 2024-06-01 at $25 and priced at $30 the day after. Average cost relieves
  # the sale at the blend, so every figure below follows from $15.20, not from
  # either parcel's own price.
  test "investment statement figures on the two-parcel fixture" do
    travel_to Time.zone.local(2024, 6, 2, 12) do
      account, security, sale = materialize_two_parcel_example(first_parcel_label: "Buy")

      assert_equal 12, cost_basis_on(account, security, Date.new(2024, 3, 4)), "the first parcel alone"
      assert_equal BigDecimal("15.2"), cost_basis_on(account, security, Date.new(2024, 5, 31)), "both parcels, before the sale"
      assert_equal BigDecimal("15.2"), cost_basis_on(account, security, Date.new(2024, 6, 1)), "the sale relieves at the blend"

      holding = @statement.current_holdings.first
      assert_equal 60, holding.qty
      assert_equal Money.new(BigDecimal("15.2"), "USD"), holding.avg_cost
      # 60 x $30 = $1,800 against 60 x $15.20 = $912.
      assert_equal Money.new(1800, "USD"), holding.trend.current
      assert_equal Money.new(912, "USD"), holding.trend.previous
      assert_equal 888, @statement.unrealized_gains

      # 40 x $25 = $1,000 against 40 x $15.20 = $608.
      gain = sale.realized_gain_loss
      assert_equal Money.new(1000, "USD"), gain.current
      assert_equal Money.new(608, "USD"), gain.previous
      assert_equal Money.new(392, "USD"), gain.value
    end
  end

  # The same fixture with the first parcel transferred in rather than bought.
  # Its cost is unknown, and today that makes the whole position unknown on
  # every date it is held: the $20 parcel's own price is not applied to the
  # transferred units, and the sale has no realized gain.
  test "investment statement figures on the two-parcel fixture with the first parcel transferred in" do
    travel_to Time.zone.local(2024, 6, 2, 12) do
      account, security, sale = materialize_two_parcel_example(first_parcel_label: Trade::TRANSFER_LABEL)

      assert_nil cost_basis_on(account, security, Date.new(2024, 3, 4))
      assert_nil cost_basis_on(account, security, Date.new(2024, 5, 31)), "not the $20 parcel's price"
      assert_nil cost_basis_on(account, security, Date.new(2024, 6, 2))

      holding = @statement.current_holdings.first
      assert_equal 60, holding.qty
      assert_nil holding.avg_cost
      assert_nil holding.trend
      assert_equal 0, @statement.unrealized_gains

      assert_nil sale.realized_gain_loss
    end
  end

  # ---------------------------------------------- allocation by classification

  test "allocation groups by asset class, and cash counts as liquidity" do
    account = create_investment_account(balance: 3000, cash_balance: 1000)
    equity = create_classified_security(asset_class: "equity", asset_sub_class: "stock")
    bond = create_classified_security(asset_class: "fixed_income", asset_sub_class: "bond")
    Holding.create!(account: account, security: equity, date: Date.current, qty: 1, price: 1200, amount: 1200, currency: "USD")
    Holding.create!(account: account, security: bond, date: Date.current, qty: 1, price: 800, amount: 800, currency: "USD")

    segments = @statement.allocation_by("asset_class").index_by(&:id)

    assert_equal %w[equity fixed_income liquidity], segments.keys.sort
    assert_equal 1200, segments["equity"].amount.amount
    assert_equal 800, segments["fixed_income"].amount.amount
    assert_equal 1000, segments["liquidity"].amount.amount, "the account's cash is liquidity"
  end

  # The bucket has to be a real segment: a portfolio of unclassified
  # securities is told it has nothing classified yet rather than handed an
  # empty list a caller would read as "nothing to show".
  test "an entirely unclassified portfolio gets one Unclassified segment, not an empty list" do
    account = create_investment_account(balance: 1000, cash_balance: 0)
    security = create_classified_security(asset_class: nil, asset_sub_class: nil)
    Holding.create!(account: account, security: security, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD")

    segments = @statement.allocation_by("asset_class")

    assert_equal 1, segments.length
    assert_equal InvestmentStatement::UNCLASSIFIED, segments.first.id
    assert_equal 1000, segments.first.amount.amount
    assert_in_delta 100, segments.first.weight, 0.01
  end

  # A cash balance is liquidity, and it is cash as a sub-class -- but it has
  # no sector and no region, and putting it in one would invent an exposure
  # the family does not have.
  test "cash lands in liquidity by asset class and in Unclassified by sector" do
    account = create_investment_account(balance: 1000, cash_balance: 1000)

    by_class = @statement.allocation_by("asset_class").index_by(&:id)
    by_sector = @statement.allocation_by("sector").index_by(&:id)
    by_sub_class = @statement.allocation_by("asset_sub_class").index_by(&:id)
    by_region = @statement.allocation_by("region").index_by(&:id)

    assert_equal 1000, by_class["liquidity"].amount.amount
    assert_equal 1000, by_sub_class["cash"].amount.amount
    assert_equal 1000, by_sector[InvestmentStatement::UNCLASSIFIED].amount.amount,
                 "cash was given a sector it does not have"
    assert_equal 1000, by_region[InvestmentStatement::UNCLASSIFIED].amount.amount,
                 "cash was given a region it does not have"
  end

  # A non-primary-currency cash POSITION is a real holding -- Security.cash_for
  # creates one per currency -- and its classification columns may be empty.
  # Reading the column alone would file the family's euros under Unclassified
  # while the account's own cash balance sits under Liquidity: two answers for
  # the same money on one chart.
  #
  # The columns are emptied with `update_columns` so the test exercises the
  # `cash?` rule whatever a callback or default would otherwise put there.
  test "a cash holding is liquidity, whatever its classification columns say" do
    account = create_investment_account(balance: 2000, cash_balance: 0)
    cash_security = Security.create!(ticker: "CASH-EUR-#{SecureRandom.hex(3)}", kind: "cash", offline: true)
    cash_security.update_columns(asset_class: nil, asset_sub_class: nil, classification_source: nil)
    assert_nil cash_security.reload.asset_class, "precondition: the taxonomy is empty here"
    Holding.create!(account: account, security: cash_security, date: Date.current,
                    qty: 1, price: 2000, amount: 2000, currency: "USD")

    by_class = @statement.allocation_by("asset_class").index_by(&:id)
    by_sub = @statement.allocation_by("asset_sub_class").index_by(&:id)

    assert_equal 2000, by_class["liquidity"]&.amount&.amount,
                 "a cash holding was filed as Unclassified"
    assert_equal 2000, by_sub["cash"]&.amount&.amount

    # And the drill-down agrees, or the parent row and its children disagree.
    children = @statement.allocation_children("asset_class", "liquidity").index_by(&:id)
    assert_equal 2000, children["cash"]&.amount&.amount
  end

  test "allocation groups by sector and region from the security's own columns" do
    account = create_investment_account(balance: 2000, cash_balance: 0)
    tech = create_classified_security(sector: "Technology", region: "north_america")
    bank = create_classified_security(sector: "Financials", region: "europe")
    Holding.create!(account: account, security: tech, date: Date.current, qty: 1, price: 1500, amount: 1500, currency: "USD")
    Holding.create!(account: account, security: bank, date: Date.current, qty: 1, price: 500, amount: 500, currency: "USD")

    by_sector = @statement.allocation_by("sector").index_by(&:id)
    by_region = @statement.allocation_by("region").index_by(&:id)

    assert_equal 1500, by_sector["Technology"].amount.amount
    assert_equal 500, by_sector["Financials"].amount.amount
    assert_equal 1500, by_region["north_america"].amount.amount
    assert_equal 500, by_region["europe"].amount.amount
  end

  test "a partly classified portfolio reports both the classified and the rest" do
    account = create_investment_account(balance: 2000, cash_balance: 0)
    known = create_classified_security(asset_class: "equity", asset_sub_class: "stock")
    unknown = create_classified_security(asset_class: nil)
    Holding.create!(account: account, security: known, date: Date.current, qty: 1, price: 1500, amount: 1500, currency: "USD")
    Holding.create!(account: account, security: unknown, date: Date.current, qty: 1, price: 500, amount: 500, currency: "USD")

    segments = @statement.allocation_by("asset_class").index_by(&:id)

    assert_equal 1500, segments["equity"].amount.amount
    assert_equal 500, segments[InvestmentStatement::UNCLASSIFIED].amount.amount
    assert_in_delta 100, segments.values.sum(&:weight), 0.02, "weights must still sum to 100"
  end

  # The drill-down: asset class -> sub-class -> holdings.
  test "an asset class expands to its sub-classes, and a sub-class to its holdings" do
    account = create_investment_account(balance: 3000, cash_balance: 0)
    stock = create_classified_security(asset_class: "equity", asset_sub_class: "stock")
    etf = create_classified_security(asset_class: "equity", asset_sub_class: "etf")
    Holding.create!(account: account, security: stock, date: Date.current, qty: 1, price: 2000, amount: 2000, currency: "USD")
    Holding.create!(account: account, security: etf, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD")

    sub_classes = @statement.allocation_children("asset_class", "equity").index_by(&:id)

    assert_equal %w[etf stock], sub_classes.keys.sort
    assert_equal 2000, sub_classes["stock"].amount.amount
    assert_equal 1000, sub_classes["etf"].amount.amount

    holdings = @statement.allocation_children("asset_sub_class", "stock")

    assert_equal 1, holdings.length
    assert_equal 2000, holdings.first.amount.amount
  end

  # Expanding Liquidity has to show the cash, or the children contradict the
  # parent row's amount.
  test "Liquidity expands to the account cash it is made of" do
    create_investment_account(balance: 1000, cash_balance: 1000)

    children = @statement.allocation_children("asset_class", "liquidity").index_by(&:id)

    assert_equal 1000, children["cash"].amount.amount
  end

  # The bottom level under Cash lists the account cash its parent counts, as ONE
  # position: two accounts' cash is one exposure, not two rows at half weight.
  # Asked with and without a parent, because Cash is reached both from
  # Liquidity (asset class first) and directly (sub-class first).
  test "two accounts' cash is one position under Cash" do
    create_investment_account(balance: 1000, cash_balance: 1000)
    create_investment_account(balance: 500, cash_balance: 500)

    [ nil, "liquidity" ].each do |parent|
      rows = @statement.allocation_children("asset_sub_class", "cash", parent: parent)

      assert_equal [ "cash" ], rows.map(&:id), "parent=#{parent.inspect}: account cash was not one position"
      assert_equal 1500, rows.first.amount.amount, "parent=#{parent.inspect}: the position was not both accounts' cash"
      assert_equal I18n.t("models.investment_statement.cash"), rows.first.name
    end
  end

  # Cash held in another currency converts into the family currency at every
  # level that counts it: 1,000 EUR at 1.1 is 1,100 USD in Liquidity and in the
  # Cash position below it, not 1,000.
  test "account cash in another currency converts at every level" do
    create_investment_account(balance: 1000, cash_balance: 1000, currency: "EUR")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.1)

    liquidity = @statement.allocation_by("asset_class").find { |s| s.id == "liquidity" }
    cash_sub = @statement.allocation_children("asset_class", "liquidity").find { |s| s.id == "cash" }
    position = @statement.allocation_children("asset_sub_class", "cash", parent: "liquidity").sole

    [ liquidity, cash_sub, position ].each_with_index do |segment, level|
      assert_equal 1100, segment.amount.amount, "level #{level}: EUR cash was not converted"
    end
  end

  # The parent counts each account's cash only where it is positive, so the
  # child does too: +1,000 and -500 is 1,000 at both levels, not a netted 500.
  # The second account's balance is 500 below the position it holds, which is
  # what makes its cash negative.
  test "negative account cash is left out below as above" do
    create_investment_account(balance: 1000, cash_balance: 1000)
    margin = create_investment_account(balance: 0, cash_balance: -500)
    Holding.create!(account: margin, security: create_classified_security(asset_class: "equity", asset_sub_class: "stock"),
                    date: Date.current, qty: 1, price: 500, amount: 500, currency: "USD")

    parent = @statement.allocation_children("asset_class", "liquidity").find { |r| r.id == "cash" }
    rows = @statement.allocation_children("asset_sub_class", "cash", parent: "liquidity")

    assert_equal 1000, parent.amount.amount, "precondition: the parent counts positive cash only"
    assert_equal [ 1000 ], rows.map { |r| r.amount.amount }, "the child cash row disagreed with its parent"
  end

  # Account cash sits on Liquidity/Cash only.
  test "account cash is not listed under a cash sub-class reached from another asset class" do
    create_investment_account(balance: 1000, cash_balance: 1000)
    assert_not_empty @statement.allocation_children("asset_sub_class", "cash", parent: "liquidity"),
                     "precondition: the cash is listed under Liquidity/Cash"

    assert_empty @statement.allocation_children("asset_sub_class", "cash", parent: "equity"),
                 "account cash was filed under equity"
    assert_empty @statement.allocation_children("asset_sub_class", "stock", parent: "liquidity"),
                 "account cash was listed outside the cash sub-class"
  end

  # One security held in a USD and a EUR account is one position of its whole
  # family-currency value, as `allocation` and `top_holdings` already report it.
  test "a security held in two accounts and two currencies is one row of the summed value" do
    usd = create_investment_account(balance: 1000, cash_balance: 0, currency: "USD")
    eur = create_investment_account(balance: 1000, cash_balance: 0, currency: "EUR")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.1)
    etf = create_classified_security(asset_class: "equity", asset_sub_class: "etf")
    Holding.create!(account: usd, security: etf, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD")
    Holding.create!(account: eur, security: etf, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "EUR")

    rows = @statement.allocation_children("asset_sub_class", "etf", parent: "equity")

    assert_equal [ etf.id ], rows.map(&:id), "the security was listed once per account"
    assert_in_delta 2100, rows.first.amount.amount, 0.0001, "1,000 USD plus 1,000 EUR at 1.1 is 2,100"
    assert_in_delta 100, rows.first.weight, 0.01
  end

  # At every level, each bucket's children add up to the bucket, from both
  # entry points of the ladder, on a portfolio with every kind of row the
  # bottom level can hold: account cash in several accounts (one negative), a
  # cash security, and one security across two accounts.
  test "every allocation level sums to the bucket above it" do
    first = create_investment_account(balance: 3000, cash_balance: 700)
    second = create_investment_account(balance: 1000, cash_balance: 300)
    create_investment_account(balance: 0, cash_balance: -200)
    stock = create_classified_security(asset_class: "equity", asset_sub_class: "stock")
    bond = create_classified_security(asset_class: "fixed_income", asset_sub_class: "bond")
    cash_security = Security.create!(ticker: "CASH-EUR-#{SecureRandom.hex(3)}", kind: "cash", offline: true)
    Holding.create!(account: first, security: stock, date: Date.current, qty: 1, price: 1200, amount: 1200, currency: "USD")
    Holding.create!(account: second, security: stock, date: Date.current, qty: 1, price: 400, amount: 400, currency: "USD")
    Holding.create!(account: first, security: bond, date: Date.current, qty: 1, price: 800, amount: 800, currency: "USD")
    Holding.create!(account: first, security: cash_security, date: Date.current, qty: 1, price: 300, amount: 300, currency: "USD")

    @statement.allocation_by("asset_class").each do |klass|
      subs = @statement.allocation_children("asset_class", klass.id)
      assert_in_delta klass.amount.amount, subs.sum { |s| s.amount.amount }, 0.0001, "#{klass.id}'s sub-classes did not sum to it"

      subs.each do |sub|
        positions = @statement.allocation_children("asset_sub_class", sub.id, parent: klass.id)
        assert_in_delta sub.amount.amount, positions.sum { |p| p.amount.amount }, 0.0001,
                        "#{klass.id}/#{sub.id}'s positions did not sum to it"
        assert_equal positions.map(&:id).uniq, positions.map(&:id), "#{klass.id}/#{sub.id} listed a position twice"
      end
    end

    @statement.allocation_by("asset_sub_class").each do |sub|
      positions = @statement.allocation_children("asset_sub_class", sub.id)
      assert_in_delta sub.amount.amount, positions.sum { |p| p.amount.amount }, 0.0001,
                      "#{sub.id}'s positions did not sum to it from the sub-class grouping"
    end
  end

  # Negative control: with no account cash and each security in one account,
  # the bottom level is the holdings as they are, row for row.
  test "a portfolio with no account cash and one holding per security lists its holdings unchanged" do
    account = create_investment_account(balance: 3000, cash_balance: 0)
    big = create_classified_security(name: "Big", asset_class: "equity", asset_sub_class: "stock")
    small = create_classified_security(name: "Small", asset_class: "equity", asset_sub_class: "stock")
    Holding.create!(account: account, security: big, date: Date.current, qty: 1, price: 2000, amount: 2000, currency: "USD")
    Holding.create!(account: account, security: small, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD")

    rows = @statement.allocation_children("asset_sub_class", "stock", parent: "equity")

    assert_equal [ [ big.id, "Big", 2000, BigDecimal("66.67") ], [ small.id, "Small", 1000, BigDecimal("33.33") ] ],
                 rows.map { |r| [ r.id, r.name, r.amount.amount, r.weight ] }
    assert_empty @statement.allocation_children("asset_sub_class", "cash", parent: "liquidity"),
                 "a cash position appeared with no cash to show"
  end

  # A sector has no sub-sector here, and inventing one would be a different
  # chart. These render flat.
  test "the groupings that do not nest return no children" do
    account = create_investment_account(balance: 1000, cash_balance: 0)
    security = create_classified_security(sector: "Technology", region: "north_america")
    Holding.create!(account: account, security: security, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD")

    %w[sector region currency account security].each do |grouping|
      assert_empty @statement.allocation_children(grouping, "Technology"), "#{grouping} invented a child level"
    end
  end

  # A sub-class name is not unique across asset classes, so the bottom level is
  # scoped to the branch it hangs from. Without it, opening equity's
  # `unclassified` also lists fixed income's, and the level reports more money
  # than the child above it.
  test "an unclassified sub-class opens onto its own asset class only" do
    account = create_investment_account(balance: 1000, cash_balance: 0)
    # asset_class set, asset_sub_class left blank -> UNCLASSIFIED in both classes.
    share = create_classified_security(ticker: "UEQ1", asset_class: "equity")
    bond = create_classified_security(ticker: "UFI1", asset_class: "fixed_income")
    Holding.create!(account: account, security: share, date: Date.current, qty: 1, price: 600, amount: 600, currency: "USD")
    Holding.create!(account: account, security: bond, date: Date.current, qty: 1, price: 400, amount: 400, currency: "USD")

    rows = @statement.allocation_children("asset_sub_class", InvestmentStatement::UNCLASSIFIED, parent: "equity")

    assert_equal [ share.id ], rows.map(&:id),
                 "fixed income's unclassified position leaked into equity's"
    assert_equal 600, rows.sum { |r| r.amount.amount }.to_i,
                 "the bottom level reported more than its parent holds"
  end

  # `build_segments` drops a non-positive ROW, which is right for a row but
  # makes the levels disagree: a sub-class holding +1,000 and -500 nets to 500
  # one level up, while the bottom level -- where they are two rows -- drops the
  # negative and reports 1,000. A negative amount is corrupt data (upsert_all
  # bypasses Holding's validations), so it is excluded before anything sums.
  test "a corrupt negative holding is excluded at every level, not just the bottom" do
    account = create_investment_account(balance: 1000, cash_balance: 0)
    good = create_classified_security(ticker: "POS1", asset_class: "equity", asset_sub_class: "stock")
    bad = create_classified_security(ticker: "NEG1", asset_class: "equity", asset_sub_class: "stock")
    Holding.create!(account: account, security: good, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD")
    corrupt = Holding.create!(account: account, security: bad, date: Date.current, qty: 1, price: 500, amount: 500, currency: "USD")
    # Holding validates a non-negative amount, so reproduce the only way one
    # lands in production: a write that skips validation.
    corrupt.update_columns(amount: -500)

    top = @statement.allocation_by("asset_class")
    equity = top.find { |r| r.id == "equity" }
    parent = @statement.allocation_children("asset_class", "equity")
    stock = parent.find { |r| r.id == "stock" }
    bottom = @statement.allocation_children("asset_sub_class", "stock", parent: "equity")

    assert_equal 1000, equity.amount.amount.to_i, "the top-level segment netted the corrupt row in"
    assert_equal 1000, stock.amount.amount.to_i, "the negative row netted against the good one a level up"
    assert_equal 1000, bottom.sum { |r| r.amount.amount }.to_i, "the bottom level disagreed with its parent"
    assert_equal [ good.id ], bottom.map(&:id), "the corrupt position was still listed"
  end

  test "every allocation grouping measures the same portfolio" do
    # One account holding securities plus cash, one all-cash: the shape the
    # groupings could disagree on, since each reads the holdings plus each
    # account's cash.
    mixed = create_investment_account(balance: 10_000, cash_balance: 2_000)
    create_investment_account(balance: 3_000, cash_balance: 3_000)
    security = create_portfolio_security
    Holding.create!(account: mixed, security: security, date: Date.current, qty: 80, price: 100, amount: 8_000, currency: "USD")

    totals = InvestmentStatement::ALLOCATION_GROUPINGS.to_h do |by|
      segments = @statement.allocation_by(by)
      assert_in_delta 100.0, segments.sum(&:weight), 0.01, "#{by} weights must sum to 100"
      [ by, segments.sum { |segment| segment.amount.amount } ]
    end

    assert_equal [ @statement.portfolio_value ], totals.values.uniq,
      "every grouping must add up to the portfolio value: #{totals.inspect}"
  end

  # ------------------------------------------ one cash rule for every grouping
  #
  # Account cash is each account's balance less its allocatable holdings, in
  # the family currency, positive only. Every grouping, and every level of the
  # asset-class drill-down, files that one figure, so all of them sum to
  # T = sum over accounts of max(balance, holdings).

  # A balance no holding accounts for and no cash_balance explains -- a manual
  # crypto account, an account never synced -- is cash in every grouping.
  test "every grouping sums to the same total when an account has a balance and no holdings" do
    coherent = create_investment_account(balance: 3000, cash_balance: 1000)
    create_crypto_account(balance: 10_000, cash_balance: 0)
    stock = create_classified_security(asset_class: "equity", asset_sub_class: "stock")
    Holding.create!(account: coherent, security: stock, date: Date.current, qty: 1, price: 2000, amount: 2000, currency: "USD")

    assert_every_grouping_and_level_sums_to 13_000
  end

  # The adapter default writes cash_balance = balance for a provider that sends
  # no cash figure. The holdings must not then be counted a second time.
  test "a cash_balance that is the whole balance is not counted twice" do
    account = create_investment_account(balance: 1500, cash_balance: 0)
    account.update_columns(cash_balance: 1500)
    stock = create_classified_security(asset_class: "equity", asset_sub_class: "stock")
    Holding.create!(account: account, security: stock, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD")

    assert_every_grouping_and_level_sums_to 1500
  end

  # 1,000 EUR at 1.1 is 1,100 USD, less a 550 USD position: 550 USD of cash.
  # Subtracting before converting gives 495; reading cash_balance gives 0. The
  # position is provider-held, since a manual holding in another currency than
  # its account's is not a current holding.
  test "account cash is the residual, converted per account" do
    account = create_investment_account(balance: 1000, cash_balance: 0, currency: "EUR")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.1)
    item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    provider = AccountProvider.create!(account: account, provider: item.coinstats_accounts.create!(name: "Brokerage", currency: "EUR"))
    stock = create_classified_security(asset_class: "equity", asset_sub_class: "stock")
    Holding.create!(account: account, security: stock, date: Date.current, qty: 1, price: 550, amount: 550, currency: "USD",
                    account_provider: provider)

    liquidity = @statement.allocation_by("asset_class").find { |s| s.id == "liquidity" }
    cash_sub = @statement.allocation_children("asset_class", "liquidity").find { |s| s.id == "cash" }
    position = @statement.allocation_children("asset_sub_class", "cash", parent: "liquidity").find { |s| s.id == "cash" }

    [ liquidity, cash_sub, position ].each_with_index do |segment, level|
      assert_in_delta 550, segment&.amount&.amount.to_f, 0.0001, "level #{level}"
    end

    assert_in_delta 1100, @statement.allocation_by("account").sole.amount.amount, 0.0001
  end

  # Margin in one account cannot net against cash in another: A is 200 below
  # its holdings, B is 500 above, so the cash is 500, not 300, and T is 2,500.
  test "an account below its holdings contributes no cash and offsets no other account's cash" do
    margin_case_accounts

    assert_equal 500, @statement.allocation_by("asset_sub_class").find { |s| s.id == "cash" }&.amount&.amount
    assert_every_grouping_and_level_sums_to 2500

    InvestmentStatement::ALLOCATION_GROUPINGS.each do |by|
      assert @statement.allocation_by(by).all? { |s| s.amount.amount.positive? }, "#{by} has a non-positive segment"
    end
  end

  # The control: balances equal holdings plus cash_balance everywhere, so
  # balance less holdings and cash_balance are the same figure and every
  # grouping, weight and top_holdings weight is what either source gives.
  test "a coherent portfolio is unchanged" do
    first = create_investment_account(balance: 3000, cash_balance: 1000)
    second = create_investment_account(balance: 500, cash_balance: 500)
    stock = create_classified_security(ticker: "STK646", name: "Stock", asset_class: "equity", asset_sub_class: "stock", sector: "Technology", region: "north_america")
    bond = create_classified_security(ticker: "BND646", name: "Bond", asset_class: "fixed_income", asset_sub_class: "bond")
    Holding.create!(account: first, security: stock, date: Date.current, qty: 1, price: 1200, amount: 1200, currency: "USD")
    Holding.create!(account: first, security: bond, date: Date.current, qty: 1, price: 800, amount: 800, currency: "USD")

    figures = ->(by) { @statement.allocation_by(by).map { |s| [ s.id, s.amount.amount.to_i, s.weight.to_f ] } }

    assert_equal [ [ "liquidity", 1500, 42.86 ], [ "equity", 1200, 34.29 ], [ "fixed_income", 800, 22.86 ] ], figures.("asset_class")
    assert_equal [ [ "unclassified", 2300, 65.71 ], [ "Technology", 1200, 34.29 ] ], figures.("sector")
    assert_equal [ [ first.id, 3000, 85.71 ], [ second.id, 500, 14.29 ] ], figures.("account")
    assert_equal [ [ "standard", 2000, 57.14 ], [ "cash", 1500, 42.86 ] ], figures.("kind")
    assert_equal [ [ "USD", 3500, 100.0 ] ], figures.("currency")
    assert_equal [ [ "STK646", 34.29 ], [ "BND646", 22.86 ] ], @statement.top_holdings.map { |h| [ h.ticker, h.weight.to_f ] }
    assert_every_grouping_and_level_sums_to 3500
  end

  # A stale zero balance beside real holdings: the account shows its holdings
  # rather than dropping out of the account grouping, and there is no cash.
  test "a stale zero balance keeps the account in the account grouping" do
    account = create_investment_account(balance: 0, cash_balance: 0)
    stock = create_classified_security(asset_class: "equity", asset_sub_class: "stock")
    Holding.create!(account: account, security: stock, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD")

    assert_equal [ [ account.id.to_s, 1000 ] ], @statement.allocation_by("account").map { |s| [ s.id, s.amount.amount ] }
    assert_nil @statement.allocation_by("kind").find { |s| s.id == "cash" }
    assert_every_grouping_and_level_sums_to 1000
  end

  # Each grouping must answer from its own column. One security with all four
  # columns set, and a different value in each, so a grouping that is missing
  # (and returns []) or that reads another grouping's column fails here.
  test "every classification grouping is reachable through allocation_by" do
    account = create_investment_account(balance: 1000, cash_balance: 0)
    security = create_classified_security(asset_class: "equity", asset_sub_class: "stock",
                                          sector: "Technology", region: "north_america")
    Holding.create!(account: account, security: security, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD")

    expected = { "asset_class" => "equity", "asset_sub_class" => "stock", "sector" => "Technology", "region" => "north_america" }
    assert_empty expected.keys - InvestmentStatement::ALLOCATION_GROUPINGS

    expected.each do |grouping, bucket|
      assert_equal [ bucket ], @statement.allocation_by(grouping).map(&:id), "#{grouping} did not group by its own column"
    end
  end

  test "allocation_by groups the portfolio by account, currency and kind with weights summing to 100" do
    usd = create_investment_account(balance: 3000, cash_balance: 1000, currency: "USD")
    eur = create_investment_account(balance: 2000, cash_balance: -50, currency: "EUR")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.1)
    stock = Security.create!(ticker: "AAPL", name: "Apple")
    coin = Security.create!(ticker: "BTCUSD", name: "Bitcoin", exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC)
    cash_security = Security.cash_for(eur)

    Holding.create!(account: usd, security: stock, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD")
    Holding.create!(account: usd, security: coin, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD")
    Holding.create!(account: eur, security: stock, date: Date.current, qty: 5, price: 200, amount: 1000, currency: "EUR")
    Holding.create!(account: eur, security: cash_security, date: Date.current, qty: 500, price: 1, amount: 500, currency: "EUR")

    by_account = @statement.allocation_by(:account)
    assert_equal [ usd.id, eur.id ].map(&:to_s), by_account.map(&:id)
    assert_equal Money.new(3000, "USD"), by_account.first.amount
    assert_in_delta 100.0, by_account.sum(&:weight), 0.01

    by_currency = @statement.allocation_by("currency")
    # Account cash is balance less holdings, not cash_balance: the EUR account's
    # 2,000 balance less its 1,500 of holdings is 500 EUR of cash, whatever its
    # cash_balance of -50 says. USD: 1000 + 1000 holdings + 1000 cash = 3000;
    # EUR: (1000 + 500 + 500) * 1.1 = 2200.
    assert_equal %w[USD EUR], by_currency.map(&:id)
    assert_equal Money.new(3000, "USD"), by_currency.first.amount
    assert_in_delta 2200, by_currency.last.amount.amount, 0.001
    assert_in_delta 100.0, by_currency.sum(&:weight), 0.01

    by_kind = @statement.allocation_by(:kind).index_by(&:id)
    # standard: 1000 + 1100; cash: 1000 USD account cash + 550 EUR cash
    # security + 550 EUR account cash; crypto: 1000
    assert_equal %w[cash crypto standard], by_kind.keys.sort
    assert_in_delta 2100, by_kind["standard"].amount.amount, 0.001
    assert_in_delta 2100, by_kind["cash"].amount.amount, 0.001
    assert_in_delta 1000, by_kind["crypto"].amount.amount, 0.001
    assert_in_delta 100.0, by_kind.values.sum(&:weight), 0.01
  end

  # The position groupings cut one portfolio three ways, so each must add up to
  # the same money as the classification groupings. The shape they could
  # disagree on: one security in two accounts and two currencies, account cash
  # in both currencies, a negative cash account, a cash security and a coin.
  # Cash goes where each grouping files it: inside its account, under its
  # account's currency, and under the cash kind.
  test "account, currency and kind each sum to the portfolio, with cash where each files it" do
    usd = create_investment_account(balance: 2500, cash_balance: 500, currency: "USD")
    eur = create_investment_account(balance: 1200, cash_balance: 200, currency: "EUR")
    create_investment_account(balance: 0, cash_balance: -100, currency: "USD")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.1)
    stock = create_classified_security(asset_class: "equity", asset_sub_class: "stock")
    coin = Security.create!(ticker: "BTCUSD", name: "Bitcoin", exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC)
    euro_cash = Security.cash_for(eur)
    Holding.create!(account: usd, security: stock, date: Date.current, qty: 1, price: 1500, amount: 1500, currency: "USD")
    Holding.create!(account: usd, security: coin, date: Date.current, qty: 1, price: 500, amount: 500, currency: "USD")
    Holding.create!(account: eur, security: stock, date: Date.current, qty: 1, price: 800, amount: 800, currency: "EUR")
    Holding.create!(account: eur, security: euro_cash, date: Date.current, qty: 200, price: 1, amount: 200, currency: "EUR")

    assert_equal %w[asset_class asset_sub_class sector region account currency kind], InvestmentStatement::ALLOCATION_GROUPINGS

    figures = ->(by) { @statement.allocation_by(by).map { |s| [ s.id, s.amount.amount.to_f.round(2) ] } }

    # Each account at its balance: USD 1500 + 500 + 500 cash; EUR (800 + 200 + 200) * 1.1.
    assert_equal [ [ usd.id.to_s, 2500.0 ], [ eur.id.to_s, 1320.0 ] ], figures.call("account")
    # The two-account stock splits by the currency each position is priced in;
    # each account's cash joins its own currency, and the negative one is left out.
    assert_equal [ [ "USD", 2500.0 ], [ "EUR", 1320.0 ] ], figures.call("currency")
    # The two-account stock is one standard figure (1500 + 880); cash is the euro
    # cash security (220) plus both accounts' positive cash (500 + 220).
    assert_equal [ [ "standard", 2380.0 ], [ "cash", 940.0 ], [ "crypto", 500.0 ] ], figures.call("kind")

    portfolio = @statement.allocation_by("asset_class").sum { |s| s.amount.amount }
    assert_in_delta 3820, portfolio, 0.001, "precondition: the classification grouping measures the whole portfolio"
    assert_in_delta @statement.portfolio_value, portfolio, 0.001

    %w[account currency kind].each do |by|
      segments = @statement.allocation_by(by)
      assert_in_delta portfolio, segments.sum { |s| s.amount.amount }, 0.001, "#{by} did not add up to the portfolio"
      assert_in_delta 100.0, segments.sum(&:weight), 0.01, "#{by} weights must sum to 100"
      assert_empty @statement.allocation_children(by, segments.first.id), "#{by} invented a child level"
    end
  end

  # The currency grouping is the currency a position is priced in, not the
  # currency of the account holding it; account cash is the account's currency.
  # Only a provider's import keeps a row priced in another currency current, so
  # the account is provider-linked.
  test "a position priced in another currency than its account groups under its own currency" do
    account = create_investment_account(balance: 1600, cash_balance: 500, currency: "USD")
    item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    provider = AccountProvider.create!(account: account, provider: item.coinstats_accounts.create!(name: "Brokerage", currency: "USD"))
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.1)
    asml = create_classified_security(ticker: "ASML1")
    Holding.create!(account: account, security: asml, date: Date.current, qty: 2, price: 500, amount: 1000, currency: "EUR",
                    account_provider: provider)

    assert_equal [ [ "EUR", 1100.0 ], [ "USD", 500.0 ] ],
                 @statement.allocation_by("currency").map { |s| [ s.id, s.amount.amount.to_f.round(2) ] }
  end

  # Same per-row rule as the classification ladder: a negative amount is corrupt
  # data (upsert_all skips Holding's validations) and must not net against a good
  # row before the grouping sums.
  test "a corrupt negative holding nets into neither the currency nor the kind grouping" do
    account = create_investment_account(balance: 1000, cash_balance: 0)
    good = create_classified_security(ticker: "POS2")
    bad = create_classified_security(ticker: "NEG2")
    Holding.create!(account: account, security: good, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD")
    corrupt = Holding.create!(account: account, security: bad, date: Date.current, qty: 1, price: 500, amount: 500, currency: "USD")
    corrupt.update_columns(amount: -500)

    assert_equal [ [ "USD", 1000 ] ], @statement.allocation_by("currency").map { |s| [ s.id, s.amount.amount.to_i ] }
    assert_equal [ [ "standard", 1000 ] ], @statement.allocation_by("kind").map { |s| [ s.id, s.amount.amount.to_i ] }
  end

  # A grouping name comes from a query string, so one that is not offered
  # answers with no segments rather than raising or borrowing another
  # grouping's answer.
  test "an unknown grouping returns no segments" do
    account = create_investment_account(balance: 1000, cash_balance: 0)
    security = create_classified_security(asset_class: "equity")
    Holding.create!(account: account, security: security, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD")
    assert_not_empty @statement.allocation_by("asset_class"), "precondition: the portfolio has segments to borrow"

    assert_empty @statement.allocation_by("nonsense")
  end

  test "previous_holdings loads the prior snapshot of every holding in one query" do
    ira = create_investment_account(balance: 5000)
    taxable = create_investment_account(balance: 3000)
    aapl = Security.create!(ticker: "AAPL", name: "Apple")
    msft = Security.create!(ticker: "MSFT", name: "Microsoft")

    [ [ ira, aapl, 10 ], [ ira, msft, 5 ], [ taxable, aapl, 4 ] ].each do |account, security, qty|
      Holding.create!(account: account, security: security, date: 2.days.ago.to_date, qty: qty, price: 100, amount: qty * 100, currency: "USD")
      Holding.create!(account: account, security: security, date: 1.day.ago.to_date, qty: qty, price: 110, amount: qty * 110, currency: "USD")
      Holding.create!(account: account, security: security, date: Date.current, qty: qty, price: 120, amount: qty * 120, currency: "USD")
    end
    # A holding with no prior snapshot has no day change.
    only_today = Security.create!(ticker: "NEW", name: "New")
    Holding.create!(account: taxable, security: only_today, date: Date.current, qty: 1, price: 50, amount: 50, currency: "USD")

    @statement.current_holdings.to_a
    queries = capture_sql_queries { @statement.previous_holdings; @statement.day_change }
    holdings_queries = queries.grep(/FROM "?holdings"?\b/)

    assert_equal 1, holdings_queries.size, "previous snapshots must come from one query, not one per holding"

    previous = @statement.previous_holdings
    current = @statement.current_holdings.index_by { |holding| [ holding.account_id, holding.security_id ] }
    assert_equal 3, previous.size
    assert_equal 1.day.ago.to_date, previous[current[[ ira.id, aapl.id ]].id].date
    assert_nil previous[current[[ taxable.id, only_today.id ]].id]

    # Same answer as the per-holding lookup, summed in family currency:
    # today 19 * 120 = 2280 vs yesterday 19 * 110 = 2090.
    day_change = @statement.day_change
    assert_equal Money.new(2280, "USD"), day_change.current
    assert_equal Money.new(2090, "USD"), day_change.previous
    per_holding = @statement.current_holdings.filter_map { |h| h.day_change }
    assert_equal per_holding.sum { |t| t.current.amount }, day_change.current.amount
  end

  test "holdings_table_rows measures a row's return over the positions whose cost basis is known" do
    ira = create_investment_account(balance: 5000, cash_balance: 500)
    taxable = create_investment_account(balance: 3000)
    aapl = Security.create!(ticker: "AAPL", name: "Apple")
    msft = Security.create!(ticker: "MSFT", name: "Microsoft")

    Holding.create!(account: ira, security: aapl, date: 1.day.ago.to_date, qty: 10, price: 190, amount: 1900, currency: "USD", cost_basis: 150, cost_basis_locked: true)
    Holding.create!(account: ira, security: aapl, date: Date.current, qty: 10, price: 200, amount: 2000, currency: "USD", cost_basis: 150, cost_basis_locked: true)
    # No stored basis and no trades in the second account, so Holding#avg_cost
    # is nil there and that position is outside the row's return.
    Holding.create!(account: taxable, security: aapl, date: Date.current, qty: 5, price: 200, amount: 1000, currency: "USD")
    Holding.create!(account: ira, security: msft, date: Date.current, qty: 4, price: 500, amount: 2000, currency: "USD", cost_basis: 400, cost_basis_locked: true)

    rows = @statement.holdings_table_rows

    assert_equal %w[AAPL MSFT], rows.map(&:ticker)
    aapl_row, msft_row = rows

    assert_equal 2, aapl_row.accounts_count
    assert_equal 15, aapl_row.qty
    assert_equal Money.new(3000, "USD"), aapl_row.amount_money
    assert aapl_row.missing_cost_basis, "one position has no known basis, so the row still warns"
    # Partial credit, the rule unrealized_gains and combined_holding_trend
    # already use: cost and return cover the 10 shares whose basis is known
    # (2000 now against 1500 cost), not the 5 that have none.
    assert_equal Money.new(150, "USD"), aapl_row.avg_cost
    assert_equal Money.new(2000, "USD"), aapl_row.unrealized.current
    assert_equal Money.new(1500, "USD"), aapl_row.unrealized.previous
    assert_equal Money.new(500, "USD"), aapl_row.unrealized.value
    # Day change from the one position with a prior snapshot: 2000 vs 1900.
    assert_equal Money.new(100, "USD"), aapl_row.day_change.value

    assert_not msft_row.missing_cost_basis
    assert_equal Money.new(400, "USD"), msft_row.avg_cost
    assert_equal Money.new(400, "USD"), msft_row.unrealized.value
    assert_nil msft_row.day_change
    # Weights use the same denominator as top_holdings: max(8000, 5000).
    assert_in_delta 37.5, aapl_row.weight, 0.01
    assert_in_delta 25.0, msft_row.weight, 0.01
  end

  test "holdings_table_rows sorts by a whitelisted key and puts rows without the figure last" do
    account = create_investment_account(balance: 6000)
    with_basis = Security.create!(ticker: "BBB", name: "Beta")
    without_basis = Security.create!(ticker: "AAA", name: "Alpha")
    big = Security.create!(ticker: "CCC", name: "Gamma")

    Holding.create!(account: account, security: with_basis, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD", cost_basis: 800, cost_basis_locked: true)
    Holding.create!(account: account, security: without_basis, date: Date.current, qty: 1, price: 2000, amount: 2000, currency: "USD")
    Holding.create!(account: account, security: big, date: Date.current, qty: 1, price: 3000, amount: 3000, currency: "USD", cost_basis: 3500, cost_basis_locked: true)

    assert_equal %w[CCC AAA BBB], @statement.holdings_table_rows.map(&:ticker), "default is value desc"
    assert_equal %w[BBB AAA CCC], @statement.holdings_table_rows(sort: "value", dir: "asc").map(&:ticker)
    assert_equal %w[AAA BBB CCC], @statement.holdings_table_rows(sort: "name", dir: "asc").map(&:ticker)
    assert_equal %w[CCC BBB AAA], @statement.holdings_table_rows(sort: "name", dir: "desc").map(&:ticker)
    # Return: BBB +200, CCC -500, AAA unknown and therefore last both ways.
    assert_equal %w[BBB CCC AAA], @statement.holdings_table_rows(sort: "return", dir: "desc").map(&:ticker)
    assert_equal %w[CCC BBB AAA], @statement.holdings_table_rows(sort: "return", dir: "asc").map(&:ticker)
    assert_equal %w[CCC AAA BBB], @statement.holdings_table_rows(sort: "drop table", dir: "sideways").map(&:ticker), "unknown keys fall back to the default"
    assert_equal %w[BBB AAA CCC], @statement.holdings_table_rows(sort: "drop table", dir: "asc").map(&:ticker), "an unknown sort keeps a valid dir"
    assert_equal %w[CCC BBB AAA], @statement.holdings_table_rows(sort: "name", dir: "sideways").map(&:ticker), "an unknown dir keeps a valid sort"
  end

  test "holdings_table_rows issues no query per holding" do
    account = create_investment_account(balance: 10_000)
    5.times do |i|
      security = Security.create!(ticker: "S#{i}", name: "Security #{i}")
      Holding.create!(account: account, security: security, date: 1.day.ago.to_date, qty: 1, price: 90, amount: 90, currency: "USD")
      Holding.create!(account: account, security: security, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD", cost_basis: 80)
    end
    @statement.current_holdings.to_a

    queries = capture_sql_queries { @statement.holdings_table_rows(sort: "day_change", dir: "desc") }

    assert_equal 1, queries.grep(/FROM "?holdings"?\b/).size, "only the previous-snapshot query may run"
    assert_empty queries.grep(/FROM "trades"|FROM "security_prices"/), "no cost-basis fallback or price lookups per row"
  end

  # Positions with no stored basis take their cost from the trade history,
  # which the table reads for every holding in one query rather than two per
  # row (Holding.preload_avg_costs).
  test "holdings_table_rows reads the trade-history cost of every holding in one query" do
    account = create_investment_account(balance: 10_000)
    3.times do |i|
      security = Security.create!(ticker: "T#{i}", name: "Traded #{i}")
      Holding.create!(account: account, security: security, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD")
      create_trade_for(account: account, security: security, qty: 10, price: 60 + i * 10, date: 1.day.ago.to_date)
    end
    @statement.current_holdings.to_a

    rows = nil
    queries = Holding.uncached { capture_sql_queries { rows = @statement.holdings_table_rows } }

    assert_equal 1, queries.grep(/FROM "trades"|JOIN trades/).size, "one batched cost query, not two per holding"
    assert_equal({ "T0" => 60, "T1" => 70, "T2" => 80 }, rows.to_h { |row| [ row.ticker, row.avg_cost.amount.to_i ] })
    assert rows.none?(&:missing_cost_basis)
  end

  # The dashboard and the report read unrealized_gains_trend before
  # top_holdings on one statement, so the gains read the trade-history cost
  # the same batched way, and top_holdings reuses it.
  test "unrealized gains read the trade-history cost of every holding in one query" do
    account = create_investment_account(balance: 10_000)
    3.times do |i|
      security = Security.create!(ticker: "G#{i}", name: "Gain #{i}")
      Holding.create!(account: account, security: security, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD")
      create_trade_for(account: account, security: security, qty: 10, price: 60 + i * 10, date: 1.day.ago.to_date)
    end
    cost_queries = ->(statement, &read) do
      statement.current_holdings.to_a
      Holding.uncached { capture_sql_queries { read.call(statement) } }.grep(/FROM "trades"|JOIN trades/).size
    end

    counts = %i[unrealized_gains unrealized_gains_trend].to_h do |method|
      [ method, cost_queries.call(InvestmentStatement.new(@family, user: nil)) { |s| s.public_send(method) } ]
    end
    assert_equal({ unrealized_gains: 1, unrealized_gains_trend: 1 }, counts)

    trend = nil
    statement = InvestmentStatement.new(@family, user: nil)
    dashboard = cost_queries.call(statement) { |s| trend = s.unrealized_gains_trend; s.top_holdings(limit: 5) }
    assert_equal 1, dashboard, "top_holdings must reuse the cost the gains read"

    # 3000 held at a cost of 600 + 700 + 800
    assert_equal Money.new(3000), trend.current
    assert_equal Money.new(2100), trend.previous
    assert_in_delta 900, statement.unrealized_gains, 0.001
  end

  # A provider can report one security in two currencies in the same account on
  # the same day, and both rows are current. Each compares against its own
  # currency's previous snapshot, as Holding#day_change does, and the portfolio
  # day change counts both. Read through the real current_holdings, not a stub,
  # so a selection that kept one row per account and security would fail here.
  test "a security held in two currencies in one account keeps a day change per currency" do
    account = create_investment_account(balance: 10_000)
    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    provider = AccountProvider.create!(account: account, provider: coinstats_item.coinstats_accounts.create!(name: "Brokerage", currency: "USD"))
    security = Security.create!(ticker: "DUAL", name: "Dual listed")
    ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: Date.current, rate: 0.5)
    # The USD snapshot is older than the CAD one, so a lookup that ignored
    # currency would hand the USD row the newer CAD snapshot.
    { "USD" => [ 100, 130, 2 ], "CAD" => [ 200, 210, 1 ] }.each do |currency, (before, now, days_ago)|
      Holding.create!(account: account, account_provider: provider, security: security, date: days_ago.days.ago.to_date, qty: 1, price: before, amount: before, currency: currency)
        .update_columns(updated_at: days_ago.days.ago) # imported that day, not today
      Holding.create!(account: account, account_provider: provider, security: security, date: Date.current, qty: 1, price: now, amount: now, currency: currency)
    end

    current = @statement.current_holdings.sort_by(&:currency)
    assert_equal %w[CAD USD], current.map(&:currency), "both currencies' rows are current"

    changes = current.to_h { |holding| [ holding.currency, @statement.holding_day_change(holding) ] }

    assert_equal Money.new(100, "USD"), changes["USD"].previous
    assert_equal Money.new(30, "USD"), changes["USD"].value
    assert_equal Money.new(200, "CAD"), changes["CAD"].previous
    assert_equal Money.new(10, "CAD"), changes["CAD"].value
    current.each do |holding|
      assert_equal holding.day_change.value, @statement.holding_day_change(holding).value, "#{holding.currency} must match Holding#day_change"
    end

    # 130 + 210 CAD at 0.5 against 100 + 200 CAD at 0.5
    assert_equal Money.new(235), @statement.day_change.current
    assert_equal Money.new(200), @statement.day_change.previous
  end

  test "holdings table rows with the same figure keep a fixed order in both directions" do
    account = create_investment_account(balance: 10_000)
    %w[Beta Alpha Gamma].each_with_index do |name, i|
      security = Security.create!(ticker: "TIE#{i}", name: name)
      Holding.create!(account: account, security: security, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD")
    end

    asc = @statement.holdings_table_rows(sort: "value", dir: "asc").map(&:name)
    desc = @statement.holdings_table_rows(sort: "value", dir: "desc").map(&:name)

    assert_equal %w[Alpha Beta Gamma], asc
    assert_equal %w[Alpha Beta Gamma], desc, "ties break by name in both directions"
  end

  # Pins top_holdings and allocation on a portfolio that exercises every path
  # the shared roll-up takes: a stored basis, the trade-history fallback, a
  # position with no basis, an internal movement, a security held in two
  # accounts and a corrupt negative row.
  test "top_holdings and allocation keep their figures on a mixed portfolio" do
    ira = create_investment_account(balance: 6000, cash_balance: 500)
    taxable = create_investment_account(balance: 3000)
    stored = Security.create!(ticker: "STO", name: "Stored")
    traded = Security.create!(ticker: "TRD", name: "Traded")
    moved = Security.create!(ticker: "MOV", name: "Moved")
    corrupt = Security.create!(ticker: "BAD", name: "Corrupt")

    Holding.create!(account: ira, security: stored, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD", cost_basis: 50, cost_basis_locked: true)
    Holding.create!(account: taxable, security: stored, date: Date.current, qty: 5, price: 100, amount: 500, currency: "USD")
    Holding.create!(account: ira, security: traded, date: Date.current, qty: 10, price: 120, amount: 1200, currency: "USD")
    create_trade_for(account: ira, security: traded, qty: 10, price: 80, date: 1.day.ago.to_date)
    Holding.create!(account: taxable, security: moved, date: Date.current, qty: 20, price: 100, amount: 2000, currency: "USD")
    create_trade_for(account: taxable, security: moved, qty: 20, price: 90, date: 1.day.ago.to_date)
      .entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL)
    Holding.create!(account: taxable, security: corrupt, date: Date.current, qty: 1, price: 300, amount: 300, currency: "USD")
      .update_columns(amount: -300)

    figures = ->(rows) { rows.map { |r| [ r.ticker, r.amount.amount.to_i, r.weight.to_f, r.trend&.current&.amount&.to_i, r.trend&.previous&.amount&.to_i ] } }

    # Denominator max(9000 portfolio, 4700 holdings) = 9000.
    expected = [
      [ "MOV", 2000, 22.22, nil, nil ],
      [ "STO", 1500, 16.67, 1000, 500 ],
      [ "TRD", 1200, 13.33, 1200, 800 ]
    ]
    assert_equal expected, figures.call(InvestmentStatement.new(@family, user: nil).top_holdings)
    assert_equal expected.first(2), figures.call(InvestmentStatement.new(@family, user: nil).top_holdings(limit: 2))
    assert_equal expected, figures.call(InvestmentStatement.new(@family, user: nil).allocation)
  end

  private
    def materialize_two_parcel_example(first_parcel_label:)
      account = create_investment_account(balance: 1800)
      security = create_portfolio_security
      Security::Price.create!(security: security, date: Date.new(2024, 6, 2), price: 30, currency: "USD")

      create_portfolio_trade(account: account, security: security, qty: 60, price: 12, date: Date.new(2024, 1, 10), label: first_parcel_label)
      create_portfolio_trade(account: account, security: security, qty: 40, price: 20, date: Date.new(2024, 3, 5), label: "Buy")
      sale = create_portfolio_trade(account: account, security: security, qty: -40, price: 25, date: Date.new(2024, 6, 1), label: "Sell")

      Holding::Materializer.new(account, strategy: :forward).materialize_holdings

      [ account, security, sale.entryable ]
    end

    def cost_basis_on(account, security, date)
      account.holdings.find_by!(security: security, date: date).cost_basis
    end

    def create_classified_security(**attrs)
      Security.create!(
        { ticker: "T#{SecureRandom.hex(6)}", exchange_operating_mic: "XNAS", offline: true }.merge(attrs)
      )
    end

    def create_investment_account(balance:, cash_balance: 0, currency: "USD")
      @family.accounts.create!(
        name: "Investment #{SecureRandom.hex(3)}",
        balance: balance,
        cash_balance: cash_balance,
        currency: currency,
        accountable: Investment.new
      )
    end

    def create_crypto_account(balance:, cash_balance: 0, currency: "USD")
      @family.accounts.create!(
        name: "Crypto #{SecureRandom.hex(3)}",
        balance: balance,
        cash_balance: cash_balance,
        currency: currency,
        accountable: Crypto.new
      )
    end

    # Account A holds 1,000 against a balance of 800 (margin); account B holds
    # 1,000 against 1,500. Returns the two securities.
    def margin_case_accounts
      margin = create_investment_account(balance: 800, cash_balance: -200)
      funded = create_investment_account(balance: 1500, cash_balance: 500)
      first = create_classified_security(asset_class: "equity", asset_sub_class: "stock")
      second = create_classified_security(asset_class: "fixed_income", asset_sub_class: "bond")
      Holding.create!(account: margin, security: first, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD")
      Holding.create!(account: funded, security: second, date: Date.current, qty: 1, price: 1000, amount: 1000, currency: "USD")
      [ first, second ]
    end

    # Every grouping sums to `expected`, and so does every level of the
    # asset-class drill-down: each segment's children sum to the segment and each
    # child's positions sum to the child.
    def assert_every_grouping_and_level_sums_to(expected)
      sum = ->(segments) { segments.sum { |s| s.amount.amount } }

      InvestmentStatement::ALLOCATION_GROUPINGS.each do |by|
        assert_in_delta expected, sum.(@statement.allocation_by(by)), 0.0001, "#{by} does not sum to #{expected}"
      end

      @statement.allocation_by("asset_class").each do |klass|
        subs = @statement.allocation_children("asset_class", klass.id)
        assert_in_delta klass.amount.amount, sum.(subs), 0.0001, "#{klass.id}'s sub-classes"

        subs.each do |sub|
          positions = @statement.allocation_children("asset_sub_class", sub.id, parent: klass.id)
          assert_in_delta sub.amount.amount, sum.(positions), 0.0001, "#{klass.id}/#{sub.id}'s positions"
        end
      end

      @statement.allocation_by("asset_sub_class").each do |sub|
        positions = @statement.allocation_children("asset_sub_class", sub.id)
        assert_in_delta sub.amount.amount, sum.(positions), 0.0001, "#{sub.id}'s positions"
      end
    end

    def create_trade_for(account:, security:, qty:, price:, date: Date.current)
      account.entries.create!(
        name: "Trade #{SecureRandom.hex(3)}",
        amount: qty * price,
        date: date,
        currency: account.currency,
        entryable: Trade.new(
          security: security,
          qty: qty,
          price: price,
          currency: account.currency
        )
      )
    end

    # Investment income (dividends, interest) is recorded as a Trade with
    # qty: 0 and price: 0, matching Trade::CreateForm#create_income_trade.
    # A negative amount means cash coming in.
    def create_income_trade(account:, label:, amount:, date:)
      account.entries.create!(
        name: "#{label} #{SecureRandom.hex(3)}",
        amount: -amount.to_d.abs,
        date: date,
        currency: account.currency,
        entryable: Trade.new(
          security: Security.create!(ticker: "T#{SecureRandom.hex(8)}", name: "Test Security"),
          qty: 0,
          price: 0,
          currency: account.currency,
          investment_activity_label: label
        )
      )
    end

    def create_portfolio_security(ticker: "T#{SecureRandom.hex(6)}")
      Security.create!(ticker: ticker, name: "Test #{ticker}")
    end

    # Manual buy/sell (Trade::CreateForm) and provider trades. The manual form
    # folds the fee into the entry amount; pass `fee_in_amount: false` for the
    # Kraken / Binance-spot shape whose amount excludes it.
    def create_portfolio_trade(account:, security: create_portfolio_security, qty:, price:, fee: 0, label: nil, date: Date.current, fee_in_amount: true, excluded: false)
      label ||= qty.negative? ? "Sell" : "Buy"
      amount = qty.to_d * price.to_d
      amount += fee.to_d if fee_in_amount

      account.entries.create!(
        name: "#{label} #{security.ticker}",
        date: date,
        amount: amount,
        currency: account.currency,
        excluded: excluded,
        entryable: Trade.new(
          qty: qty,
          price: price,
          fee: fee,
          currency: account.currency,
          security: security,
          investment_activity_label: label
        )
      )
    end

    # Trading212 / IBKR / Questrade: a Transaction with the label and the
    # security id in extra. Negative amount = cash in.
    def create_income_transaction(account:, label:, amount:, security: create_portfolio_security, date: Date.current, extra_shape: :flat)
      extra = case extra_shape
      when :flat then { "security_id" => security.id }
      when :nested then { "security" => { "id" => security.id } }
      else {}
      end

      account.entries.create!(
        name: "#{label} from #{security.ticker}",
        date: date,
        amount: -amount.to_d.abs,
        currency: account.currency,
        entryable: Transaction.new(investment_activity_label: label, extra: extra)
      )
    end

    # PlaidAccount::Investments::TransactionsProcessor routes a cash dividend
    # through the trade path with quantity 0, so the amount is 0 * price = 0.
    def create_plaid_dividend_trade(account:, security: create_portfolio_security, price: 100, date: Date.current)
      account.entries.create!(
        name: "Dividend #{security.ticker}",
        date: date,
        amount: 0,
        currency: account.currency,
        entryable: Trade.new(qty: 0, price: price, fee: 0, currency: account.currency, security: security, investment_activity_label: "Dividend")
      )
    end

    def create_labelled_transaction(account:, label:, amount:, kind: "standard", date: Date.current, extra: {}, excluded: false)
      account.entries.create!(
        name: "#{label || 'Transaction'} #{SecureRandom.hex(2)}",
        date: date,
        amount: amount,
        currency: account.currency,
        excluded: excluded,
        entryable: Transaction.new(investment_activity_label: label, kind: kind, extra: extra)
      )
    end

    # A linked Transfer exactly as Transfer::Creator writes it: the outflow leg
    # is investment_contribution when the destination is an investment account,
    # the inflow leg is funds_movement, and optional fee legs point back at the
    # transfer through transfer_id.
    def create_linked_transfer(family:, from:, to:, amount:, date: Date.current, source_fee_amount: nil)
      Transfer::Creator.new(
        family: family,
        source_account_id: from.id,
        destination_account_id: to.id,
        date: date,
        amount: amount,
        source_fee_amount: source_fee_amount
      ).create
    end

    def create_trade(account:, qty:, amount:, date:)
      account.entries.create!(
        name: "Trade #{SecureRandom.hex(3)}",
        amount: amount,
        date: date,
        currency: account.currency,
        entryable: Trade.new(
          security: Security.create!(ticker: "T#{SecureRandom.hex(8)}", name: "Test Security"),
          qty: qty,
          price: amount.to_d.abs / qty.to_d.abs,
          currency: account.currency
        )
      )
    end
end
