require "test_helper"

class Holding::CostBasisTrackerTest < ActiveSupport::TestCase
  setup do
    @tracker = Holding::CostBasisTracker.new
  end

  test "average cost is nil with no trades" do
    assert_nil @tracker.average_cost
  end

  test "weighted average across multiple buys" do
    @tracker.apply(BigDecimal("100"), BigDecimal("10"))
    @tracker.apply(BigDecimal("200"), BigDecimal("10"))

    assert_equal BigDecimal("150"), @tracker.average_cost
  end

  test "a partial sell leaves the per-share average unchanged" do
    @tracker.apply(BigDecimal("100"), BigDecimal("10"))
    @tracker.apply(BigDecimal("200"), BigDecimal("10")) # avg 150

    # Sell price is irrelevant to cost basis; shares are relieved at the average.
    @tracker.apply(BigDecimal("999"), BigDecimal("-5"))

    assert_equal BigDecimal("150"), @tracker.average_cost
  end

  test "cost basis resets after a full liquidation and repurchase" do
    @tracker.apply(BigDecimal("100"), BigDecimal("10"))
    @tracker.apply(BigDecimal("300"), BigDecimal("-10")) # fully sold

    assert_nil @tracker.average_cost

    @tracker.apply(BigDecimal("300"), BigDecimal("10")) # repurchased

    # Only the repurchased lot is held — not (100 + 300) / 2 = 200.
    assert_equal BigDecimal("300"), @tracker.average_cost
  end

  test "over-selling cannot drive quantity or basis negative" do
    @tracker.apply(BigDecimal("100"), BigDecimal("5"))
    @tracker.apply(BigDecimal("100"), BigDecimal("-10")) # sell more than held

    assert_nil @tracker.average_cost
  end

  test "selling with no position is a no-op" do
    @tracker.apply(BigDecimal("100"), BigDecimal("-5"))

    assert_nil @tracker.average_cost
  end

  test "coerces float quantities so a full liquidation still resets" do
    # Float inputs must not accumulate rounding error that leaves a tiny
    # residual quantity and bypasses the reset-on-full-liquidation.
    @tracker.apply(100.0, 10.0)
    @tracker.apply(300.0, -10.0)

    assert_nil @tracker.average_cost

    @tracker.apply(300.0, 10.0)

    assert_equal BigDecimal("300"), @tracker.average_cost
  end
end
