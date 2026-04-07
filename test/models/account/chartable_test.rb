require "test_helper"

class Account::ChartableTest < ActiveSupport::TestCase
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
end
