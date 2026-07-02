require "test_helper"

class TrendTest < ActiveSupport::TestCase
  test "handles money trend" do
    trend = Trend.new(current: Money.new(100), previous: Money.new(50))
    assert_equal "up", trend.direction
    assert_equal Money.new(50), trend.value
    assert_equal 100.0, trend.percent
  end

  test "up" do
    trend = Trend.new(current: 100, previous: 50)
    assert_equal "up", trend.direction
    assert_equal "var(--color-success)", trend.color
  end

  test "down" do
    trend = Trend.new(current: 50, previous: 100)
    assert_equal "down", trend.direction
    assert_equal "var(--color-destructive)", trend.color
  end

  test "flat" do
    trend1 = Trend.new(current: 100, previous: 100)
    trend2 = Trend.new(current: 100, previous: nil)
    assert_equal "flat", trend1.direction
    assert_equal "up", trend2.direction
    assert_equal "var(--color-gray)", trend1.color
  end

  test "infinitely up" do
    trend = Trend.new(current: 100, previous: 0)
    assert_equal "up", trend.direction
  end

  test "infinitely down" do
    trend = Trend.new(current: 0, previous: 100)
    assert_equal "down", trend.direction
  end

  test "negative baseline reports percent with the direction's sign" do
    # Improving from -100 to -50 is an upward move of +50%, not -50%.
    trend = Trend.new(current: -50, previous: -100)
    assert_equal "up", trend.direction
    assert_equal 50.0, trend.percent
    assert_equal "50.0%", trend.percent_formatted
  end

  test "negative baseline getting worse reports a negative percent" do
    # Falling from -50 to -100 is a downward move of -100%.
    trend = Trend.new(current: -100, previous: -50)
    assert_equal "down", trend.direction
    assert_equal(-100.0, trend.percent)
  end

  test "infinite percent carries the direction's sign" do
    up = Trend.new(current: 100, previous: 0)
    assert_equal Float::INFINITY, up.percent
    assert_equal "＋∞", up.percent_formatted

    down = Trend.new(current: -100, previous: 0)
    assert_equal(-Float::INFINITY, down.percent)
    assert_equal "-∞", down.percent_formatted
  end
end
