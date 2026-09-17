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

  # A 10% year on a billion. Newton's steps shrink below RATE_TOLERANCE while the
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

  # Every loss reaches bisection, so the low end of its bracket decides whether
  # an ordinary loss has a rate at all. A fixed -0.999999 floor meant dividing
  # by 1e-6 ** units, which underflows to zero past about 51 units and made the
  # present value Infinity: bisection saw a non-finite endpoint and gave up, and
  # `rate` reported "did not converge" for a series it had never searched.
  #
  # Both fixtures are ordinary shapes in the unit this class offers callers --
  # a 30% loss over a year read weekly, a 50% loss over 100 days read daily --
  # and both raised ConvergenceError before the endpoint was derived per series.
  # Closed form: a single outlay A returning B after t units solves exactly at
  # (B/A) ** (1/t) - 1, so the expected figures here are not the solver's own.
  test "an ordinary loss is solved however many units it spans" do
    start = Date.new(2026, 1, 1)

    weekly = Portfolio::Xirr.rate(
      [ [ start, -1_000 ], [ start + 364, 700 ] ], days_per_unit: 7
    )
    assert_in_delta (700.0 / 1_000)**(7.0 / 364) - 1, weekly.to_f, 1e-9,
                    "52 weekly units: a 30% loss has a rate, and this is it"

    daily = Portfolio::Xirr.rate(
      [ [ start, -1_000 ], [ start + 100, 500 ] ], days_per_unit: 1
    )
    assert_in_delta (500.0 / 1_000)**(1.0 / 100) - 1, daily.to_f, 1e-9,
                    "100 daily units: likewise"
  end

  # The other direction of the same defect. A fixed floor is not only too low
  # for a long span, it is needlessly high for a short one: a near-total loss
  # over a single year has a real rate below -99.9999%, and nothing about the
  # arithmetic at one unit of span puts it out of reach. Deriving the endpoint
  # from the series reaches it.
  test "a near total loss over one unit is solved rather than refused" do
    rate = Portfolio::Xirr.rate([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2027, 1, 1), 0.0001 ]
    ])

    assert_in_delta(-0.9999999, rate.to_f, 1e-9, "0.0001 back on 1,000 in one year")
  end

  # The bracket only moves as far from -1 as the arithmetic forces it to, so a
  # short span keeps an endpoint that a long one cannot afford. Pinning both
  # ends stops a future "just use a safer constant" from quietly reintroducing
  # either half of the defect above.
  test "the low endpoint is derived from the series, not fixed" do
    start = Date.new(2026, 1, 1)

    short = Portfolio::Xirr.new([ [ start, -1_000 ], [ start + 365, 500 ] ])
    long = Portfolio::Xirr.new([ [ start, -1_000 ], [ start + 365 * 60, 500 ] ])

    assert_operator short.send(:low_endpoint), :<, -0.99999,
                    "one unit of span can be evaluated hard against -1"
    assert_operator long.send(:low_endpoint), :>, short.send(:low_endpoint),
                    "sixty units cannot, and the endpoint has to back off"
    assert_operator long.send(:low_endpoint), :<, 0.0,
                    "but it is still a low end, not a positive rate"

    assert Float::INFINITY > short.send(:present_value, short.send(:low_endpoint)).abs,
           "the endpoint the bracket uses must be one the objective can be evaluated at"
    assert Float::INFINITY > long.send(:present_value, long.send(:low_endpoint)).abs
  end

  # The third rescue branch, which no fixture reaches: bisection searches from a
  # derived low endpoint up to 1e7, and a series that changes sign almost always puts a root
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

  # -1000, +2700, -1800 on three annual dates is 1000x^2 - 2700x + 1800 = 0 for
  # x = 1 + r, whose roots are 1.2 and 1.5: 20% and 50% both satisfy the series
  # exactly, and neither is more "correct" than the other.
  #
  # The decision this pins is that the figure is the root the search reaches
  # from its 10% start -- the lower one here -- rather than a refusal. Refusing
  # every series that changes sign twice would refuse most real portfolios: one
  # withdrawal between two deposits is two sign changes. What a caller must not
  # do is print it as THE money-weighted return without asking #ambiguous?.
  test "a series with two valid rates returns the one the search reaches, and says it is ambiguous" do
    flows = [
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2027, 1, 1), 2_700 ],
      [ Date.new(2028, 1, 1), -1_800 ]
    ]

    xirr = Portfolio::Xirr.new(flows)

    assert_in_delta 0.0, xirr.send(:present_value, 0.2), 1e-9, "0.2 must actually solve it"
    assert_in_delta 0.0, xirr.send(:present_value, 0.5), 1e-9, "and so must 0.5, or there is one root"

    assert_in_delta 0.2, xirr.rate.to_f, 1e-9
    assert xirr.ambiguous?, "two sign changes, so the figure is one of several"
    assert_equal 2, xirr.sign_changes
  end

  # The ordinary shape -- money out, money back -- has one sign change and one
  # root, so nothing is hedged for the common case.
  test "an ordinary series is not ambiguous" do
    xirr = Portfolio::Xirr.new([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2026, 6, 1), -500 ],
      [ Date.new(2027, 1, 1), 1_800 ]
    ])

    assert_equal 1, xirr.sign_changes
    assert_not xirr.ambiguous?
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

    # rate_or_nil is the variant a render path calls, and it must forward the
    # unit. One that dropped it would return nil here -- the assertion above
    # establishes that the annual form is unreachable on this fixture -- so a
    # silently-annualised rate_or_nil cannot pass this line.
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
