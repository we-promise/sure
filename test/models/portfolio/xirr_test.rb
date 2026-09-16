require "test_helper"

class Portfolio::XirrTest < ActiveSupport::TestCase
  # Money that only ever went one way has no rate of return: there
  # is no r for which the present value crosses zero. Returning a plausible
  # number here would be inventing one.
  test "raises when the series never changes sign" do
    flows = [
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2026, 6, 1), -1_000 ]
    ]

    assert_raises Portfolio::Xirr::NoSignChangeError do
      Portfolio::Xirr.rate(flows)
    end

    assert_nil Portfolio::Xirr.rate_or_nil(flows),
               "the render path must degrade to nil rather than raise"
  end

  # A year, a single outlay, a single return: the rate is the plain growth.
  test "solves a simple one year doubling" do
    rate = Portfolio::Xirr.rate([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2027, 1, 1), 2_000 ]
    ])

    assert_in_delta 1.0, rate.to_f, 0.0005, "1000 -> 2000 over one year is 100%"
  end

  test "solves a flat series at zero" do
    rate = Portfolio::Xirr.rate([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2027, 1, 1), 1_000 ]
    ])

    assert_in_delta 0.0, rate.to_f, 0.0005
  end

  # 1,000 in at the start, 1,000 more at six months, 2,200 out at twelve.
  #
  # Sanity check first, because it is the one an author can do in their head:
  # the first 1,000 was invested for a full year and the second for half of one,
  # so the weighted capital is 1,000 + 500 = 1,500, and a 200 gain on 1,500 is
  # 13.3%. Compounding lifts it slightly.
  #
  # Exactly, with t = 182/365 = 0.49863 and x = 1 + r, the closed form is
  #   -1000x - 1000·x^0.50137 + 2200 = 0
  # At x = 1.1346 the left side is -1134.60 - 1065.37 + 2200 ≈ 0.03, so the root
  # is 0.1346.
  test "solves an irregular series with a mid period contribution" do
    rate = Portfolio::Xirr.rate([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2026, 7, 2), -1_000 ],
      [ Date.new(2027, 1, 1), 2_200 ]
    ])

    assert_in_delta 0.1346, rate.to_f, 0.002
  end

  test "handles a loss" do
    rate = Portfolio::Xirr.rate([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2027, 1, 1), 500 ]
    ])

    assert_in_delta(-0.5, rate.to_f, 0.0005)
  end

  # Halving over a year. From its 10% starting guess Newton's first step lands
  # below -100%, outside the domain, so it hands over; bisection finds -50%.
  # Asserting that Newton alone gives up is what proves the fallback ran.
  test "falls back to bisection when newton leaves the domain" do
    flows = [
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2027, 1, 1), 500 ]
    ]
    xirr = Portfolio::Xirr.new(flows)

    assert_nil xirr.send(:newton_rate), "the fixture must defeat Newton, or this proves nothing"
    assert_in_delta(-0.5, xirr.rate.to_f, 0.0005)
  end

  # A 10% year on a billion. Newton's steps shrink below TOLERANCE while the
  # present-value residual, in currency units, stays near 1.2e-7: at this
  # magnitude an absolute 1e-9 residual is out of reach in Float. A step that
  # small means Newton stopped moving, not that it solved, so it must hand over
  # rather than report the stalled guess; bisection then finds 10%.
  test "newton hands a stalled step to bisection when the residual is out of reach" do
    flows = [
      [ Date.new(2026, 1, 1), -1_000_000_000 ],
      [ Date.new(2027, 1, 1), 1_100_000_000 ]
    ]
    xirr = Portfolio::Xirr.new(flows)

    assert_nil xirr.send(:newton_rate), "a small step without a small residual is not a solution"
    assert_in_delta 0.1, xirr.rate.to_f, 0.000001
  end

  # A fivefold gain in 30 days annualises to 5^(365/30) - 1, about 3.2e8. That
  # is above RATE_CEILING, so bisection could not find it; Newton must, and to
  # the right magnitude, not merely to some positive number.
  test "newton solves a steep series whose root lies beyond the bisection bracket" do
    rate = Portfolio::Xirr.rate([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2026, 1, 31), 5_000 ]
    ])

    expected = (5.0**(365.0 / 30)) - 1
    assert_operator expected, :>, Portfolio::Xirr::RATE_CEILING
    assert_in_delta expected, rate.to_f, expected * 1e-6
  end

  test "raises when every flow falls on one date" do
    flows = [
      [ Date.new(2026, 3, 2), -1_000 ],
      [ Date.new(2026, 3, 2), 1_000 ]
    ]

    assert_raises(Portfolio::Xirr::NoDurationError) { Portfolio::Xirr.rate(flows) }
    assert_nil Portfolio::Xirr.rate_or_nil(flows)
  end

  # The third rescue branch, which no fixture reaches: bisection searches
  # [-0.999999, 1e7], and a series that changes sign almost always puts a root
  # somewhere in it -- I tried three shapes built to defeat both methods (a
  # bigger outflow after an inflow, an alternating series, a near-zero terminal
  # value) and all three converged. What is pinned here is the CONTRACT rather
  # than a numeric case: when neither method solves, the answer is an error and
  # a nil, never the last guess either method held.
  test "a series neither method solves has no rate, not the guess it stopped on" do
    flows = [
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2027, 1, 1), 2_000 ]
    ]

    Portfolio::Xirr.any_instance.stubs(:newton_rate).returns(nil)
    Portfolio::Xirr.any_instance.stubs(:bisection_rate).returns(nil)

    assert_raises(Portfolio::Xirr::ConvergenceError) { Portfolio::Xirr.rate(flows) }
    assert_nil Portfolio::Xirr.rate_or_nil(flows),
               "the render path degrades to nil here too, or it raises in a view"
  end

  test "ignores zero amounts" do
    rate = Portfolio::Xirr.rate([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2026, 6, 1), 0 ],
      [ Date.new(2027, 1, 1), 2_000 ]
    ])

    assert_in_delta 1.0, rate.to_f, 0.0005
  end

  test "accepts flow objects as well as pairs" do
    flows = [
      Portfolio::Xirr::Flow.new(date: Date.new(2026, 1, 1), amount: -1_000),
      Portfolio::Xirr::Flow.new(date: Date.new(2027, 1, 1), amount: 2_000)
    ]

    assert_in_delta 1.0, Portfolio::Xirr.rate(flows).to_f, 0.0005
  end

  test "orders flows by date regardless of input order" do
    unordered = Portfolio::Xirr.rate([
      [ Date.new(2027, 1, 1), 2_000 ],
      [ Date.new(2026, 1, 1), -1_000 ]
    ])

    assert_in_delta 1.0, unordered.to_f, 0.0005
  end

  # The control for every test below: the default unit is a year, so nothing
  # that does not ask for a period rate changes.
  test "the rate is annualised unless a unit is asked for" do
    flows = [ [ Date.new(2026, 1, 1), -1_000 ], [ Date.new(2027, 1, 1), 2_000 ] ]

    assert_in_delta 1.0, Portfolio::Xirr.rate(flows).to_f, 0.0005
    assert_equal Portfolio::Xirr::DAYS_PER_YEAR, Portfolio::Xirr.new(flows).days_per_unit
  end

  # A rate over the period is the same root as the annual rate, read in a
  # different unit: (1 + period) ** (days / 365) == 1 + annual. Intermediate
  # flows are in the series because the identity is not special to two flows.
  test "a period rate and the annual rate are the same root in different units" do
    start = Date.new(2026, 3, 2)
    flows = [ [ start, -1_000.0 ], [ start + 10, -500.0 ], [ start + 30, 1_600.0 ] ]

    annual = Portfolio::Xirr.rate(flows).to_f
    period = Portfolio::Xirr.rate(flows, days_per_unit: 30).to_f

    assert_in_delta annual, (1 + period)**(365 / 30.0) - 1, 1e-9
  end

  # Why the period form is solved rather than the annual one de-annualised.
  # A day's gain of this size needs an annual rate of about 7.5e109, which is
  # outside the bracket Newton reaches, so the annual form reports nothing at
  # all. The period form is an ordinary number.
  test "a short period rate is reported where the annual form cannot be solved" do
    start = Date.new(2026, 3, 2)
    flows = [ [ start, -1_000.0 ], [ start + 1, 2_000.0 ] ]

    assert_nil Portfolio::Xirr.rate_or_nil(flows), "the annual form is expected to be unreachable here"
    assert_in_delta 1.0, Portfolio::Xirr.rate(flows, days_per_unit: 1).to_f, 1e-9

    # The render path is the one production takes: Performance#money_weighted
    # calls rate_or_nil, not rate. A rate_or_nil that dropped the unit would
    # return nil here -- the assertion above establishes that the annual form
    # is unreachable on this fixture -- so this pins the forwarding that the
    # only caller of this class depends on.
    assert_in_delta 1.0, Portfolio::Xirr.rate_or_nil(flows, days_per_unit: 1).to_f, 1e-9
  end

  # An infinite unit is positive, so a bare positivity check lets it through,
  # and it makes every elapsed interval zero: the present value stops depending
  # on the rate and Newton hands back its 10% starting guess as an answer.
  test "a unit that is not a positive finite number of days is refused" do
    flows = [ [ Date.new(2026, 1, 1), -1_000 ], [ Date.new(2027, 1, 1), 2_000 ] ]

    assert_raises(ArgumentError) { Portfolio::Xirr.new(flows, days_per_unit: 0) }
    assert_raises(ArgumentError) { Portfolio::Xirr.new(flows, days_per_unit: -30) }
    assert_raises(ArgumentError) { Portfolio::Xirr.new(flows, days_per_unit: Float::INFINITY) }
    assert_raises(ArgumentError) { Portfolio::Xirr.new(flows, days_per_unit: Float::NAN) }
  end
end
