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

  # A step below RATE_TOLERANCE means Newton stopped moving, which is not the
  # same as having solved: on an ill-conditioned stretch it stalls far from any
  # root, and returning the rate there reports a guess as an answer. So the
  # residual is confirmed before the step is accepted, and a stall hands over
  # to bisection instead.
  #
  # -50,000 out, 500 and 20,000 back, 100 out again, on four annual dates: the
  # stall fires at about -0.99493 with a residual of -4.8e-6 against a tolerance
  # of 7.1e-8. What is pinned is the handover, not the stalling rate -- the
  # figure must come from bisection, and it must be a rate the objective
  # actually crosses zero at.
  test "newton hands a stalled step to bisection rather than reporting it" do
    flows = [
      [ Date.new(2026, 1, 1), -50_000 ],
      [ Date.new(2027, 1, 1), 500 ],
      [ Date.new(2028, 1, 1), 20_000 ],
      [ Date.new(2029, 1, 1), -100 ]
    ]
    xirr = Portfolio::Xirr.new(flows)

    assert_nil xirr.send(:newton_rate), "a small step without a small residual is not a solution"

    rate = xirr.rate.to_f
    below = xirr.send(:present_value, rate - 1e-8)
    above = xirr.send(:present_value, rate + 1e-8)

    assert_operator below * above, :<, 0,
                    "the reported rate must sit on a sign change, i.e. on a root"
  end

  # Money scale is not part of the question. The same series written in cents
  # and in billions is the same series, and an ABSOLUTE residual tolerance made
  # it two different ones: below the tolerance every present value looks solved,
  # and above it none of them do.
  #
  # Both halves are pinned. The tiny one accepted Newton's untouched 10% start
  # because its whole present value is smaller than 1e-9; the billion-dollar one
  # stalled at a residual of 1.2e-7, which is Float noise at that magnitude and
  # not an unsolved series, and had to be rescued by bisection.
  test "the same series scaled up or down solves to the same rate" do
    shape = [
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2027, 1, 1), -250 ],
      [ Date.new(2028, 1, 1), 1_400 ]
    ]

    ordinary = Portfolio::Xirr.rate(shape).to_f
    tiny = Portfolio::Xirr.rate(shape.map { |date, amount| [ date, amount * 1e-12 ] }).to_f
    huge = Portfolio::Xirr.rate(shape.map { |date, amount| [ date, amount * 1e9 ] }).to_f

    assert_in_delta ordinary, tiny, 1e-9, "the same question in picodollars has the same answer"
    assert_in_delta ordinary, huge, 1e-9, "and so does the same question in billions"

    # The two-flow form, where the closed rate is exact and PyXIRR agrees: a
    # doubling is 100% whether the amounts are 1e-12 or 1.
    assert_in_delta 1.0,
                    Portfolio::Xirr.rate([
                      [ Date.new(2026, 1, 1), -1e-12 ],
                      [ Date.new(2027, 1, 1), 2e-12 ]
                    ]).to_f,
                    0.0005

    # And the 10% year on a billion is now Newton's own answer rather than a
    # stall handed to bisection.
    billion = Portfolio::Xirr.new([
      [ Date.new(2026, 1, 1), -1_000_000_000 ],
      [ Date.new(2027, 1, 1), 1_100_000_000 ]
    ])

    assert_in_delta 0.1, billion.send(:newton_rate), 1e-9
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

  # Two flows on one date share an exponent, so `present_value` cancels them
  # however they were written -- but `sign_changes` counted them separately, and
  # a pair that cancels looked like a sign change. So -1000 and +1000 on one day
  # followed by +100 passed the "money has to go both ways" guard and handed the
  # solver a series that is only +100 and has no root. It returned
  # 15,118,284,881,800% rather than raising.
  #
  # Same-date flows are summed before any of that, so the guard now sees the
  # series that actually exists.
  test "flows on one date are summed before the sign-change guard" do
    flows = [
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2026, 1, 1), 1_000 ],
      [ Date.new(2027, 1, 1), 100 ]
    ]

    assert_raises Portfolio::Xirr::NoSignChangeError do
      Portfolio::Xirr.rate(flows)
    end
    assert_nil Portfolio::Xirr.rate_or_nil(flows)
  end

  # The invariant behind that fix, and the one worth keeping: whether a caller
  # pre-nets its rows must not change the answer. Money in and out on one day is
  # ordinary -- a buy and a sell, a deposit spent the moment it lands -- and a
  # caller that groups by date should not get a different figure from one that
  # does not.
  test "a netted series and the same series written out agree" do
    start = Date.new(2026, 1, 1)
    finish = Date.new(2027, 1, 1)

    # The deposit is listed before the purchase it funds, so unsummed this
    # reads +500, -1500, +2000 -- two sign changes, and therefore "ambiguous"
    # -- where the series it describes changes sign once. Ordering rows within
    # a day must not decide whether the caller is told its figure is one of
    # several.
    written_out = Portfolio::Xirr.new([
      [ start, 500 ], [ start, -1_500 ], [ finish, 2_000 ]
    ])
    pre_netted = Portfolio::Xirr.new([ [ start, -1_000 ], [ finish, 2_000 ] ])

    assert_in_delta pre_netted.rate.to_f, written_out.rate.to_f, 1e-12
    assert_in_delta 1.0, written_out.rate.to_f, 0.0005, "and both are the doubling"

    assert_equal pre_netted.sign_changes, written_out.sign_changes
    assert_not written_out.ambiguous?, "one deposit and one withdrawal is one sign change"
  end

  # A date whose flows cancel contributes nothing and drops out with the zeros,
  # so it cannot supply a phantom term to the present value.
  test "a date whose flows net to nothing drops out" do
    start = Date.new(2026, 1, 1)
    xirr = Portfolio::Xirr.new([
      [ start, -1_000 ],
      [ Date.new(2026, 6, 1), 750 ],
      [ Date.new(2026, 6, 1), -750 ],
      [ Date.new(2027, 1, 1), 2_000 ]
    ])

    assert_equal [ start, Date.new(2027, 1, 1) ], xirr.flows.map(&:date)
    assert_in_delta 1.0, xirr.rate.to_f, 0.0005
  end

  # A bracket endpoint can BE the root, and the sign test cannot see it: a
  # residual of exactly zero makes the product zero rather than negative, so
  # bisection walked past a solved endpoint and converged on whichever end the
  # interval collapsed towards.
  #
  # -1 today and Float::EPSILON a year later is a total loss, and it solves
  # exactly at the low endpoint. It returned RATE_CEILING -- a 1,000,000,000%
  # gain reported for losing everything.
  test "a root sitting exactly on a bracket endpoint is returned, not walked past" do
    flows = [ [ Date.new(2026, 1, 1), -1 ], [ Date.new(2027, 1, 1), Float::EPSILON ] ]
    xirr = Portfolio::Xirr.new(flows)

    assert_in_delta 0.0, xirr.send(:present_value, xirr.send(:low_endpoint)), 1e-12,
                    "the fixture must actually solve at the endpoint, or this proves nothing"
    assert_operator xirr.rate.to_f, :<, -0.99,
                    "losing everything is about -100%, not the top of the bracket"
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

  # The same defect once more, at the other end of the search. Backing away from
  # -1 by doubling reaches -0.5 and then stops: the next distance is 1.0, the
  # loop's own limit, so everything between -0.5 and 0 was never probed. That
  # interval is where a long series' only evaluable endpoint lives, because
  # 0.5 ** units underflows to zero past about 1,074 units and every candidate
  # at or below -0.5 is Infinity.
  #
  # Both fixtures are ordinary shapes in the units this class offers: a 10%
  # loss over three years read daily, and the same loss over twenty years read
  # weekly. Newton cannot rescue either -- from its 10% start the derivative
  # underflows to zero at these exponents -- so the endpoint decides whether
  # there is an answer at all, and both raised ConvergenceError.
  test "a span too long to evaluate at minus a half is solved above it" do
    start = Date.new(2006, 1, 1)

    daily = Portfolio::Xirr.rate(
      [ [ start, -1_000 ], [ start + 1_095, 900 ] ], days_per_unit: 1
    )
    # RATE_TOLERANCE is the width bisection stops at, so 1e-9 is the accuracy
    # the class offers and the closed form is what it is measured against.
    assert_in_delta (900.0 / 1_000)**(1.0 / 1_095) - 1, daily.to_f, 1e-9,
                    "1,095 daily units: a 10% loss over three years has a rate"

    weekly = Portfolio::Xirr.rate(
      [ [ start, -1_000 ], [ start + 7_600, 900 ] ], days_per_unit: 7
    )
    assert_in_delta (900.0 / 1_000)**(7.0 / 7_600) - 1, weekly.to_f, 1e-9,
                    "1,085 weekly units: likewise"
  end

  # What the endpoint for such a series has to look like, so the fix above
  # cannot be satisfied by widening the doubling loop's limit past 1.0 -- which
  # would hand bisection a positive "low" end and a bracket that excludes every
  # negative rate.
  test "an endpoint above minus a half is still a negative rate the objective can be evaluated at" do
    start = Date.new(2006, 1, 1)
    xirr = Portfolio::Xirr.new([ [ start, -1_000 ], [ start + 1_095, 900 ] ], days_per_unit: 1)
    endpoint = xirr.send(:low_endpoint)

    assert_not_nil endpoint, "a series this class can solve must have an endpoint to solve it from"
    assert_operator endpoint, :>, -0.5, "nothing at or below -0.5 can be evaluated at 1,095 units"
    assert_operator endpoint, :<, 0.0, "it is still the low end of the bracket"
    assert xirr.send(:present_value, endpoint).finite?,
           "an endpoint bisection cannot evaluate is not an endpoint"
    assert_operator endpoint, :<, xirr.rate.to_f,
                    "and the root has to be inside the bracket it opens"
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

  # BOTH ends of the widest bracket can sit on the same side of zero while roots
  # sit between them, and a single global bracket cannot see it. +1, -5, +3 on
  # three annual dates is 1 - 5u + 3u**2 for u = 1 / (1 + r), whose roots are
  # (3 -/+ sqrt 13) / 2: about -30.2776% and about +330.2776%, both inside the
  # supported range. The present value is positive at the low endpoint and
  # positive at the ceiling, Newton misses from its 10% start, and the series
  # was refused outright although it has two ordinary answers.
  #
  # What is pinned: the refusal is gone, and the figure returned is a rate the
  # objective actually crosses zero at rather than any number at all.
  test "a series whose roots both sit inside the bracket is solved, not refused" do
    flows = [
      [ Date.new(2026, 1, 1), 1 ],
      [ Date.new(2027, 1, 1), -5 ],
      [ Date.new(2028, 1, 1), 3 ]
    ]

    xirr = Portfolio::Xirr.new(flows)
    low = xirr.send(:low_endpoint)

    assert_operator xirr.send(:present_value, low) * xirr.send(:present_value, Portfolio::Xirr::RATE_CEILING),
                    :>, 0,
                    "the premise: no sign change across the widest bracket"
    assert_nil xirr.send(:newton_rate), "and Newton does not reach either root from 10%"

    lower_root = (3 - Math.sqrt(13)) / 2
    assert_in_delta lower_root, xirr.rate.to_f, 1e-8,
                    "the scan walks up from the low end, so it reaches the lower root"
    assert xirr.ambiguous?, "two sign changes, so the caller is told there may be another"
  end

  # Near -1 the objective is astronomically steep, and there the residual stops
  # measuring how close the rate is. -1, -1,000,000, +1 on three annual dates
  # has one exact root, -0.999999; bisection returns it to within 3.4e-11 while
  # the present value AT that rate is about -33,487,331, because one Float tick
  # of `1 + r` is a ten-billionth of it there.
  #
  # So bisection accepts on bracket width as well as on residual, and the width
  # is the stronger claim of the two: the loop only ever replaces an endpoint
  # with one of the same sign, so the two ends bracket a sign change on every
  # iteration and a width below RATE_TOLERANCE puts the root inside it. Gating
  # acceptance on the residual alone would refuse a rate that is right to ten
  # decimal places.
  test "a rate near minus one is accepted on bracket width, not on its residual" do
    flows = [
      [ Date.new(2026, 1, 1), -1 ],
      [ Date.new(2027, 1, 1), -1_000_000 ],
      [ Date.new(2028, 1, 1), 1 ]
    ]

    xirr = Portfolio::Xirr.new(flows)
    rate = xirr.rate.to_f

    assert_in_delta(-0.999999, rate, 1e-9, "the closed-form root of 1 - 1e6 u + u**2 at u = 1 / (1 + r)")

    residual = xirr.send(:present_value, rate)
    assert_operator residual.abs, :>, xirr.send(:residual_tolerance),
                    "the premise: the residual there is nowhere near zero"
    assert_operator xirr.send(:present_value, rate - 1e-9) * xirr.send(:present_value, rate + 1e-9),
                    :<, 0,
                    "and yet the root is inside one RATE_TOLERANCE of the answer"
  end

  # Flows landing on one date are summed in Float, and Float addition is not
  # associative: -1e16, +1 and +1e16 add to 1.0 or to 0.0 depending on the
  # order, and a lost +1 is the difference between a series that solves and one
  # refused for never changing sign.
  #
  # Ruby's Enumerable#sum compensates for that (Kahan-Babuska) where a hand
  # written `inject(0.0, :+)` does not, so the answer does not depend on the
  # order the caller happened to list a day's rows in. That is a property of
  # the method chosen, not of the arithmetic, so it is pinned here: every
  # permutation of the same day must give the same rate.
  test "the order of same date flows does not change the answer" do
    on_the_day = [ -1e16, 1.0, 1e16 ]

    rates = on_the_day.permutation.map do |amounts|
      flows = amounts.map { |amount| [ Date.new(2026, 1, 1), amount ] }
      flows << [ Date.new(2027, 1, 1), -2.0 ]

      Portfolio::Xirr.rate(flows).to_f
    end

    assert_equal 1, rates.uniq.size, "six orderings, one answer: #{rates.inspect}"
    assert_in_delta 1.0, rates.first, 0.0005, "1 in and 2 out a year later is 100%"
  end

  # The predicate is an upper bound, not a count, and this is the case that
  # shows the difference: -1000, +2000, -1000 annually is -1000(x-1)**2 for
  # x = 1/(1+r), so it has ONE distinct root at 0 with multiplicity two, and
  # `ambiguous?` still reports true.
  #
  # That is the documented, deliberate direction -- counting distinct roots
  # would mean solving for all of them on a render path -- and it is pinned
  # here so the docs and the behaviour cannot drift apart again.
  test "ambiguous? is an upper bound, so it can flag a series with one root" do
    xirr = Portfolio::Xirr.new([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2027, 1, 1), 2_000 ],
      [ Date.new(2028, 1, 1), -1_000 ]
    ])

    assert_in_delta 0.0, xirr.send(:present_value, 0.0), 1e-9, "0 solves it"

    # 1e-5 rather than the 1e-9 the residual tolerance would suggest, and the
    # gap is the double root, not slack. Near a simple root the present value
    # falls off linearly with the rate, so a residual of e buys a rate accurate
    # to about e; near a double root it falls off with the SQUARE, so the same
    # residual buys only sqrt(e). Here that is sqrt(4e-9 / 1000), about 2e-6.
    assert_in_delta 0.0, xirr.rate.to_f, 1e-5, "and it is the only rate that does"
    assert_equal 2, xirr.sign_changes
    assert xirr.ambiguous?, "two sign changes, so the bound says 'possibly', not 'is'"
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

  # `flows` is a public reader, and every derived figure on the instance is
  # memoised from it: sign_changes, terms, first_date, residual_tolerance and
  # rate itself. An exposed mutable array lets a caller change the flows the
  # object reports while it goes on answering from the cache built before the
  # change -- 1000 doubling over a year returns 100%, a third flow of -5000 is
  # appended, and the instance still says 100% with one sign change while
  # showing three rows.
  #
  # The Flow objects are Data and already frozen, so the array is the whole of
  # the mutable surface.
  test "the flows a caller can see cannot be changed underneath the figures" do
    xirr = Portfolio::Xirr.new([
      [ Date.new(2026, 1, 1), -1_000 ],
      [ Date.new(2027, 1, 1), 2_000 ]
    ])

    assert_in_delta 1.0, xirr.rate.to_f, 0.0005

    assert xirr.flows.frozen?, "the exposed array is the object's own state"
    assert xirr.flows.all?(&:frozen?), "and so is every row in it"

    assert_raises FrozenError do
      xirr.flows << Portfolio::Xirr::Flow.new(date: Date.new(2028, 1, 1), amount: -5_000.0)
    end
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
