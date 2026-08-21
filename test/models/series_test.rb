require "test_helper"

class SeriesTest < ActiveSupport::TestCase
  test "a change between two values that print identically reads as no change" do
    series = build_series(previous: 100.001, current: 100.004, currency: "USD")

    trend = series.as_json[:values].last[:trend]

    # Both amounts format as $100.00
    assert_equal 0, trend.value.amount
    assert trend.direction.flat?
  end

  test "rounds the trend at the currency's display precision" do
    series = build_series(previous: 1000.4, current: 1000.6, currency: "JPY")

    trend = series.as_json[:values].last[:trend]

    # ¥1,000 -> ¥1,001
    assert_equal 1, trend.value.amount
    assert trend.direction.up?
  end

  test "does not serialize a sub-unit residue the chart would plot as a move" do
    # A leftover cent fraction (400 - 199.9999 - 200) prints as $0.00, but the
    # chart is drawn from the amount, so an unrounded 0.0001 fills the y axis
    series = build_series(previous: 0, current: 0.0001, currency: "USD")

    assert_equal 0, series.as_json[:values].last[:value].amount
  end

  test "leaves the series values themselves exact" do
    series = build_series(previous: 100.001, current: 100.004, currency: "USD")

    # Insights, goals and the assistant read the values directly
    assert_equal 100.004, series.values.last.value.amount
    assert_equal 0.003, series.values.last.trend.value.amount
  end

  test "the series trend ignores a change that is not visible" do
    # The account chart renders this trend right above the chart itself
    series = build_series(previous: 0, current: 0.0001, currency: "USD")

    assert series.trend.direction.flat?
    assert_equal 0, series.trend.value.amount
    assert series.trend.percent.finite?
  end

  private
    def build_series(previous:, current:, currency:)
      Series.new(
        start_date: Date.new(2026, 6, 1),
        end_date: Date.new(2026, 6, 2),
        interval: "1 day",
        values: [
          Series::Value.new(
            date: Date.new(2026, 6, 1),
            date_formatted: "June 1, 2026",
            value: Money.new(previous, currency),
            trend: Trend.new(
              current: Money.new(previous, currency),
              previous: Money.new(previous, currency),
              favorable_direction: "up"
            )
          ),
          Series::Value.new(
            date: Date.new(2026, 6, 2),
            date_formatted: "June 2, 2026",
            value: Money.new(current, currency),
            trend: Trend.new(
              current: Money.new(current, currency),
              previous: Money.new(previous, currency),
              favorable_direction: "up"
            )
          )
        ]
      )
    end
end
