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

  # Skipping a buy whose price is unknown would average the known buys over
  # fewer units than are held.
  test "a buy at an unknown price makes the average unknown until the position closes" do
    @tracker.apply(BigDecimal("100"), BigDecimal("10"))
    @tracker.apply(nil, BigDecimal("10"))
    assert_nil @tracker.average_cost

    @tracker.apply(BigDecimal("999"), BigDecimal("-5"))
    assert_nil @tracker.average_cost, "a partial sell does not make it known"

    @tracker.apply(BigDecimal("999"), BigDecimal("-15"))
    @tracker.apply(BigDecimal("120"), BigDecimal("4"))
    assert_equal BigDecimal("120"), @tracker.average_cost, "a repurchase after a full close starts clean"
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

  # A split changes how many shares the money bought, not how much it cost.
  # Quantity is read back by selling down: the position empties (and the
  # average resets to nil) on exactly the last share, and not one before it.
  test "a 2-for-1 split doubles the shares, keeps the total cost and halves the average" do
    @tracker.apply(BigDecimal("100"), BigDecimal("10")) # 1,000 for 10

    @tracker.split(2)

    assert_equal BigDecimal("50"), @tracker.average_cost
    @tracker.apply(BigDecimal("1"), BigDecimal("-19"))
    assert_equal BigDecimal("50"), @tracker.average_cost, "20 shares after the split, so 19 sold leaves one"
    @tracker.apply(BigDecimal("1"), BigDecimal("-1"))
    assert_nil @tracker.average_cost
  end

  test "a 1-for-10 reverse split cuts the shares and keeps the total cost" do
    @tracker.apply(BigDecimal("5"), BigDecimal("100")) # 500 for 100

    @tracker.split(Rational(1, 10))

    assert_equal BigDecimal("50"), @tracker.average_cost
    @tracker.apply(BigDecimal("1"), BigDecimal("-9"))
    assert_equal BigDecimal("50"), @tracker.average_cost, "10 shares after the split, so 9 sold leaves one"
    @tracker.apply(BigDecimal("1"), BigDecimal("-1"))
    assert_nil @tracker.average_cost
  end

  # Multiplying a BigDecimal by Rational(1, 3) rounds at 32 digits: three
  # shares became 0.999..., and the average 30.000...03. (A sale would not
  # show it: the over-sell guard clears the position either way.)
  test "a 1-for-3 reverse split of three shares leaves exactly one, at exactly three times the cost" do
    @tracker.apply(BigDecimal("10"), BigDecimal("3"))

    @tracker.split(Rational(1, 3))

    assert_equal BigDecimal("30"), @tracker.average_cost
  end

  test "a split with nothing held leaves nothing held" do
    @tracker.split(2)

    assert_nil @tracker.average_cost
    @tracker.apply(BigDecimal("30"), BigDecimal("1"))
    assert_equal BigDecimal("30"), @tracker.average_cost
  end
end
