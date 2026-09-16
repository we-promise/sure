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
    assert_equal Float::INFINITY, trend.percent
  end

  test "infinitely down" do
    trend = Trend.new(current: 0, previous: 100)
    assert_equal "down", trend.direction
  end

  test "percent sign tracks direction when the base is negative" do
    # Net worth improving from -100 to -50 is a +50% change, not -50%.
    improving = Trend.new(current: -50, previous: -100)
    assert_equal "up", improving.direction
    assert_equal 50.0, improving.percent

    # Net worth worsening from -100 to -150 is a -50% change.
    worsening = Trend.new(current: -150, previous: -100)
    assert_equal "down", worsening.direction
    assert_equal(-50.0, worsening.percent)
  end

  test "percent carries the sign of current when the base is zero" do
    assert_equal(-Float::INFINITY, Trend.new(current: -100, previous: 0).percent)
    assert_equal Float::INFINITY, Trend.new(current: 100, previous: 0).percent
  end
end
