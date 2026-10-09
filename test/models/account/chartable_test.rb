require "test_helper"

class Account::ChartableTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper
  test "generates series and memoizes" do
    account = accounts(:depository)

    test_series = mock
    builder1 = mock
    builder2 = mock

    Balance::ChartSeriesBuilder.expects(:new)
      .with(
        account_ids: [ account.id ],
        currency: account.currency,
        period: Period.last_30_days,
        favorable_direction: account.favorable_direction,
        interval: nil
      )
      .returns(builder1)
      .once

    Balance::ChartSeriesBuilder.expects(:new)
      .with(
        account_ids: [ account.id ],
        currency: account.currency,
        period: Period.last_90_days, # Period changed, so memoization should be invalidated
        favorable_direction: account.favorable_direction,
        interval: nil
      )
      .returns(builder2)
      .once

    builder1.expects(:balance_series).returns(test_series).twice
    series1 = account.balance_series
    memoized_series1 = account.balance_series

    builder2.expects(:balance_series).returns(test_series).twice
    builder2.expects(:cash_balance_series).returns(test_series).once
    builder2.expects(:holdings_balance_series).returns(test_series).once

    series2 = account.balance_series(period: Period.last_90_days)
    memoized_series2 = account.balance_series(period: Period.last_90_days)
    memoized_series2_cash_view = account.balance_series(period: Period.last_90_days, view: :cash_balance)
    memoized_series2_holdings_view = account.balance_series(period: Period.last_90_days, view: :holdings_balance)
  end

  test "supports gains view and rejects unknown views" do
    account = accounts(:investment)

    test_series = Series.new(
      start_date: Period.last_30_days.start_date,
      end_date: Period.last_30_days.end_date,
      interval: "1 day",
      values: [],
      favorable_direction: account.favorable_direction
    )

    builder = mock
    Balance::ChartSeriesBuilder.expects(:new).returns(builder)
    builder.expects(:gains_series).returns(test_series)

    assert_equal test_series, account.balance_series(view: :gains)

    assert_raises(ArgumentError) { account.balance_series(view: :bogus) }
  end

  test "trims placeholder history for linked investment accounts without trades" do
    account = accounts(:investment)
    account.entries.destroy_all
    account.holdings.destroy_all

    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    account.holdings.create!(
      security: securities(:aapl),
      date: 5.days.ago.to_date,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      account_provider: account.account_providers.last
    )

    raw_series = Series.new(
      start_date: 10.days.ago.to_date,
      end_date: Date.current,
      interval: "1 day",
      values: [
        Series::Value.new(date: 10.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: 9.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: 8.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: 5.days.ago.to_date, date_formatted: "", value: Money.new(100, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(110, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    builder = mock
    Balance::ChartSeriesBuilder.expects(:new).returns(builder)
    builder.expects(:balance_series).returns(raw_series)

    series = account.balance_series

    assert_equal 5.days.ago.to_date, series.start_date
    assert_equal [ 5.days.ago.to_date, Date.current ], series.values.map(&:date)
  end

  test "trims unstable provider snapshot history for linked investment accounts without trades" do
    account = accounts(:investment)
    account.entries.destroy_all
    account.holdings.destroy_all

    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    account.holdings.create!(
      security: securities(:aapl),
      date: 5.days.ago.to_date,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      account_provider: account.account_providers.last
    )
    account.holdings.create!(
      security: securities(:aapl),
      date: 4.days.ago.to_date,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      account_provider: account.account_providers.last
    )
    account.holdings.create!(
      security: securities(:msft),
      date: Date.current,
      qty: 1,
      price: 120,
      amount: 120,
      currency: "USD",
      account_provider: account.account_providers.last
    )

    raw_series = Series.new(
      start_date: 5.days.ago.to_date,
      end_date: Date.current,
      interval: "1 day",
      values: [
        Series::Value.new(date: 5.days.ago.to_date, date_formatted: "", value: Money.new(100, "USD")),
        Series::Value.new(date: 4.days.ago.to_date, date_formatted: "", value: Money.new(101, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(120, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    builder = mock
    Balance::ChartSeriesBuilder.expects(:new).returns(builder)
    builder.expects(:balance_series).returns(raw_series)

    series = account.balance_series

    assert_equal Date.current, series.start_date
    assert_equal [ Date.current ], series.values.map(&:date)
  end

  test "prepends inception anchor point when coarse periodic sampling misses opening date" do
    account = accounts(:investment)
    account.entries.destroy_all
    account.holdings.destroy_all

    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    opening_date = 8.days.ago.to_date
    account.set_opening_anchor_balance(balance: 0, date: opening_date)
    account.entries.create!(
      name: "Opening Trade",
      date: opening_date,
      amount: 100,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )

    raw_series = Series.new(
      start_date: 10.days.ago.to_date,
      end_date: Date.current,
      interval: "1 week",
      values: [
        Series::Value.new(date: 10.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: 3.days.ago.to_date, date_formatted: "", value: Money.new(100, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(110, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    builder = mock
    Balance::ChartSeriesBuilder.expects(:new).returns(builder)
    builder.expects(:balance_series).returns(raw_series)

    series = account.balance_series

    assert_equal opening_date, series.start_date
    assert_equal [ opening_date, 3.days.ago.to_date, Date.current ], series.values.map(&:date)
    assert_equal Money.new(0, "USD"), series.values.first.value
  end

  test "does not normalize balance series for unlinked accounts" do
    account = accounts(:depository) # Unlinked account

    raw_series = Series.new(
      start_date: 5.years.ago.to_date,
      end_date: Date.current,
      interval: "1 month",
      values: [
        Series::Value.new(date: 5.years.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(100, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    builder = mock
    Balance::ChartSeriesBuilder.expects(:new).returns(builder)
    builder.expects(:balance_series).returns(raw_series)

    series = account.balance_series(period: Period.from_key("last_5_years"))
    assert_same raw_series, series
  end

  test "prepends opening anchor with non-zero balance when coarse sampling misses opening date" do
    account = accounts(:investment)
    account.entries.destroy_all
    account.holdings.destroy_all

    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    opening_date = 8.days.ago.to_date
    account.set_opening_anchor_balance(balance: 1500, date: opening_date)
    account.entries.create!(
      name: "Opening Trade",
      date: opening_date,
      amount: 100,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )

    raw_series = Series.new(
      start_date: 10.days.ago.to_date,
      end_date: Date.current,
      interval: "1 week",
      values: [
        Series::Value.new(date: 10.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: 3.days.ago.to_date, date_formatted: "", value: Money.new(1600, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(1700, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    builder = mock
    Balance::ChartSeriesBuilder.expects(:new).returns(builder)
    builder.expects(:balance_series).returns(raw_series)

    series = account.balance_series

    assert_equal opening_date, series.start_date
    assert_equal [ opening_date, 3.days.ago.to_date, Date.current ], series.values.map(&:date)
    assert_equal Money.new(1500, "USD"), series.values.first.value
  end

  test "prepends anchor at 0 on trade date when linked account has no opening valuation" do
    account = accounts(:investment)
    account.entries.destroy_all
    account.holdings.destroy_all

    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    trade_date = 8.days.ago.to_date
    account.entries.create!(
      name: "First Trade Without Anchor",
      date: trade_date,
      amount: 100,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )

    raw_series = Series.new(
      start_date: 10.days.ago.to_date,
      end_date: Date.current,
      interval: "1 week",
      values: [
        Series::Value.new(date: 10.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: 3.days.ago.to_date, date_formatted: "", value: Money.new(100, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(110, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    builder = mock
    Balance::ChartSeriesBuilder.expects(:new).returns(builder)
    builder.expects(:balance_series).returns(raw_series)

    series = account.balance_series

    assert_equal trade_date, series.start_date
    assert_equal [ trade_date, 3.days.ago.to_date, Date.current ], series.values.map(&:date)
    assert_equal Money.new(0, "USD"), series.values.first.value
  end

  test "balance_series with view :gains synthesizes 0 gains for prepended anchor point" do
    account = accounts(:investment)
    account.entries.destroy_all
    account.holdings.destroy_all

    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    opening_date = 8.days.ago.to_date
    account.set_opening_anchor_balance(balance: 5000, date: opening_date)
    account.entries.create!(
      name: "Opening Trade",
      date: opening_date,
      amount: 100,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )

    raw_gains_series = Series.new(
      start_date: 10.days.ago.to_date,
      end_date: Date.current,
      interval: "1 week",
      values: [
        Series::Value.new(date: 10.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: 3.days.ago.to_date, date_formatted: "", value: Money.new(200, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(250, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    builder = mock
    Balance::ChartSeriesBuilder.expects(:new).returns(builder)
    builder.expects(:gains_series).returns(raw_gains_series)

    series = account.balance_series(view: :gains)

    assert_equal opening_date, series.start_date
    assert_equal [ opening_date, 3.days.ago.to_date, Date.current ], series.values.map(&:date)
    assert_equal Money.new(0, "USD"), series.values.first.value
  end

  test "balance_series does not prepend anchor outside requested period for older linked account" do
    account = accounts(:investment)
    account.entries.destroy_all
    account.holdings.destroy_all

    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    opening_date = 2.years.ago.to_date
    account.set_opening_anchor_balance(balance: 0, date: opening_date)
    account.entries.create!(
      name: "Old Trade",
      date: opening_date,
      amount: 100,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )

    thirty_days_ago = 30.days.ago.to_date
    raw_series = Series.new(
      start_date: thirty_days_ago,
      end_date: Date.current,
      interval: "1 day",
      values: [
        Series::Value.new(date: thirty_days_ago, date_formatted: "", value: Money.new(500, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(550, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    builder = mock
    Balance::ChartSeriesBuilder.expects(:new).returns(builder)
    builder.expects(:balance_series).returns(raw_series)

    series = account.balance_series(period: Period.last_30_days)

    assert_equal thirty_days_ago, series.start_date
    assert_equal [ thirty_days_ago, Date.current ], series.values.map(&:date)
    assert_equal Money.new(500, "USD"), series.values.first.value
  end

  test "balance_series assigns 0 to prepended anchor when trade predates later opening anchor" do
    account = accounts(:investment)
    account.entries.destroy_all
    account.holdings.destroy_all

    coinstats_item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account.account_providers.create!(provider: coinstats_account)

    early_trade_date = 15.days.ago.to_date
    later_anchor_date = 8.days.ago.to_date

    account.set_opening_anchor_balance(balance: 5000, date: later_anchor_date)
    account.entries.create!(
      name: "Early Trade",
      date: early_trade_date,
      amount: 100,
      currency: "USD",
      source: "snaptrade",
      entryable: Transaction.new
    )

    raw_series = Series.new(
      start_date: 20.days.ago.to_date,
      end_date: Date.current,
      interval: "1 week",
      values: [
        Series::Value.new(date: 20.days.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: 10.days.ago.to_date, date_formatted: "", value: Money.new(100, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(5100, "USD"))
      ],
      favorable_direction: account.favorable_direction
    )

    builder = mock
    Balance::ChartSeriesBuilder.expects(:new).returns(builder)
    builder.expects(:balance_series).returns(raw_series)

    series = account.balance_series

    assert_equal early_trade_date, series.start_date
    assert_equal [ early_trade_date, 10.days.ago.to_date, Date.current ], series.values.map(&:date)
    assert_equal Money.new(0, "USD"), series.values.first.value
  end

  # The view is accepted beside the others and is drawn on the value line's
  # own dates.
  test "balance_series accepts the net contributions view on the value line's dates" do
    day_one = Date.new(2026, 3, 2)
    account = create_portfolio_account(family: families(:empty))
    lay_balance account: account, date: day_one, opening: 1_000, closing: 1_000
    lay_balance account: account, date: day_one + 1, opening: 1_000, closing: 1_550, cash_flow: 500, market_flow: 50
    deposit account: account, date: day_one + 1, amount: 500
    period = Period.custom(start_date: day_one, end_date: day_one + 1)

    series = account.balance_series(period: period, view: :net_contributions, interval: "1 day")

    assert_equal account.balance_series(period: period, interval: "1 day").values.map(&:date), series.values.map(&:date)
    assert_equal [ 1_000, 1_500 ], series.values.map { |v| v.value.amount }
    assert_raises(ArgumentError) { account.balance_series(view: :contributions) }
  end

  # A linked account's value line is
  # trimmed to the first real broker activity, so its first balance row is not
  # where the chart starts. The contributions line opens on the trimmed line's
  # first date at that point's value. Anchored on the first balance row
  # instead, it would open at 1,000 + 500 = 1,500 against a value of 1,600.
  test "a linked account's net contributions open where its trimmed value line does" do
    day_one = Date.new(2026, 3, 2)
    account = create_portfolio_account(family: families(:empty))
    account.stubs(:linked?).returns(true)
    lay_balance account: account, date: day_one, opening: 1_000, closing: 1_000
    lay_balance account: account, date: day_one + 1, opening: 1_000, closing: 1_000
    lay_balance account: account, date: day_one + 2, opening: 1_000, closing: 1_600, cash_flow: 500, market_flow: 100
    lay_balance account: account, date: day_one + 3, opening: 1_600, closing: 1_900, cash_flow: 300
    account.entries.create!(name: "Deposit", date: day_one + 2, amount: -500, currency: "USD", source: "plaid",
                            entryable: Transaction.new(kind: "standard"))
    deposit account: account, date: day_one + 3, amount: 300
    period = Period.custom(start_date: day_one, end_date: day_one + 3)

    value = account.balance_series(period: period, interval: "1 day")
    contributions = account.balance_series(period: period, view: :net_contributions, interval: "1 day")

    assert_equal day_one + 2, value.values.first.date, "the value line is trimmed to the first broker activity"
    assert_equal value.values.first.date, contributions.values.first.date
    assert_equal value.values.first.value, contributions.values.first.value
    assert_equal [ 1_600, 1_900 ], contributions.values.map { |v| v.value.amount }
  end

  # On a coarse interval the trim date is not sampled, so the
  # normalizer prepends a synthetic opening point (here 0) to the value line.
  # The contributions line starts from that same point, then carries the
  # trim day's close plus later flows, rather than opening at a different
  # figure on the same day.
  test "on a coarse interval a linked account's net contributions start from the value line's own opening point" do
    day_one = Date.new(2026, 3, 2)
    account = create_portfolio_account(family: families(:empty))
    account.stubs(:linked?).returns(true)
    lay_balance account: account, date: day_one, opening: 1_000, closing: 1_000
    lay_balance account: account, date: day_one + 2, opening: 1_000, closing: 1_600, cash_flow: 500, market_flow: 100
    lay_balance account: account, date: day_one + 10, opening: 1_600, closing: 1_900, cash_flow: 300
    account.entries.create!(name: "Deposit", date: day_one + 2, amount: -500, currency: "USD", source: "plaid",
                            entryable: Transaction.new(kind: "standard"))
    deposit account: account, date: day_one + 10, amount: 300
    period = Period.custom(start_date: day_one, end_date: day_one + 14)

    value = account.balance_series(period: period, interval: "1 week")
    contributions = account.balance_series(period: period, view: :net_contributions, interval: "1 week")

    assert_equal day_one + 2, value.values.first.date, "the normalizer prepends the trim date"
    assert_equal value.values.map(&:date), contributions.values.map(&:date)
    assert_equal value.values.first.value, contributions.values.first.value, "both lines open at the same point"
    assert_equal [ 0, 1_600, 1_900 ], contributions.values.map { |v| v.value.amount }
    assert_equal 0, contributions.values[1].trend.previous.amount, "the trend follows the replaced opening point"
  end

  # The understated check reads the same flows as the line: a deposit in a
  # currency with no rate at all makes it true.
  test "net_contributions_understated? reports a flow with no rate" do
    day_one = Date.new(2026, 3, 2)
    account = create_portfolio_account(family: families(:empty))
    lay_balance account: account, date: day_one, opening: 1_000, closing: 1_000
    period = Period.custom(start_date: day_one, end_date: day_one + 1)

    refute account.net_contributions_understated?(period: period, interval: "1 day"), "every flow valued"

    deposit account: account, date: day_one + 1, amount: 100, currency: "EUR"

    assert Account.find(account.id).net_contributions_understated?(period: period, interval: "1 day"),
           "a flow with no rate, read by a fresh instance since the builder is memoized"
  end
end
