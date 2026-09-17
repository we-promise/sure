# The internal rate of return of an irregularly-timed series of cash flows --
# the money-weighted return of a portfolio, where TWR answers what the
# investments did and this answers what the investor got.
#
# Newton-Raphson with a bisection fallback. Newton converges in a handful
# of iterations on ordinary portfolios; bisection is slower but cannot diverge,
# so it catches the pathological series -- large early withdrawals, near-zero
# terminal values -- where Newton's derivative sends it off to infinity. Every
# loss takes the bisection path, because Newton's first step from its 10% start
# leaves the domain on one, so the bracket bisection searches is load-bearing
# for a whole half of the ordinary cases rather than only for exotic ones.
#
# ARITHMETIC NOTE. Money in this codebase is BigDecimal, but root-finding
# needs `(1 + r) ** (days / 365.0)` with a fractional exponent, which BigDecimal
# cannot do without BigMath.exp/log at a chosen precision -- slow, and delicate
# around r near -1. The iteration therefore runs in Float, which carries about
# fifteen significant digits for a figure displayed to two decimal places, and
# the result is returned as a BigDecimal. Amounts are converted once on the way
# in. This is the deliberate exception to the BigDecimal rule the money figures
# elsewhere follow.
#
# MULTIPLE ROOTS. The present value is a generalised polynomial in the rate, so
# a series that changes sign more than once can cross zero twice inside the
# bracket, and two rates are then equally "the" answer. -1000, +2700, -1800 on
# three annual dates is solved by both 20% and 50%.
#
# This returns the root the search reaches from its 10% start, which is the
# lower one for that series and is what every other XIRR does -- Excel's takes
# a `guess` argument for exactly this reason. It is a deliberate choice rather
# than an accident, because the alternative, refusing every series that changes
# sign twice, refuses most real portfolios: any account with a withdrawal
# between two deposits changes sign twice.
#
# `#ambiguous?` is how a caller finds out. A figure from an ambiguous series is
# one of several rates that fit, and a page that prints it as "the" money-
# weighted return is overstating what was computed. The caller that renders
# this is a later PR; the predicate is here so that PR has something to ask.
#
# No gem: AGENTS.md asks for Rails and few dependencies, and this is eighty
# lines of arithmetic with no upstream to track.
class Portfolio::Xirr
  # The flows never change sign, so no rate exists -- money only ever went in, or
  # only ever came out. Callers render "not available"; they must not substitute
  # a guess.
  class NoSignChangeError < StandardError; end

  # Neither method reached the tolerance inside the iteration cap.
  class ConvergenceError < StandardError; end

  # Every flow falls on the same date, so no time passes and no annual rate
  # exists. Without this check the present value is the same at every rate,
  # and Newton returns its starting guess of 10% as if it had solved.
  class NoDurationError < StandardError; end

  Flow = Data.define(:date, :amount)

  DAYS_PER_YEAR = 365.0
  MAX_NEWTON_ITERATIONS = 50
  MAX_BISECTION_ITERATIONS = 200
  # Two different quantities, deliberately named apart. RESIDUAL_TOLERANCE is a
  # present value -- money -- and says the objective is close enough to zero;
  # RATE_TOLERANCE is a rate, and says the search has stopped moving. They
  # carry the same number today and mean different things, and reading one
  # `TOLERANCE` in both places invited the assumption that they must match.
  RESIDUAL_TOLERANCE = 1e-9
  RATE_TOLERANCE = 1e-9

  # The high end of the bracket we search. 1e7 is 1,000,000,000% -- absurd as
  # a return, but the bracket only has to contain the root, not be plausible.
  RATE_CEILING = 1.0e7

  # The low end is never -1, where the objective is undefined (a total loss of
  # every future-dated flow), and it is not a constant either: how close to -1
  # the arithmetic can get depends on the series. See #low_endpoint. The search
  # starts one Float tick above -1 -- below EPSILON, `-1.0 + distance` IS -1.0
  # -- and backs off from there.
  NARROWEST_FLOOR_DISTANCE = Float::EPSILON

  attr_reader :flows, :days_per_unit

  # `flows` is any enumerable of objects answering `date` and `amount`, or
  # [date, amount] pairs. Sign convention: money leaving the investor is
  # negative, money returning to them is positive. The terminal value of the
  # portfolio is the final positive flow.
  #
  # `days_per_unit` is the length of the unit the rate is expressed in. The
  # default is a year, so `rate` is the annualised figure by default and every
  # existing caller is unaffected. A caller reporting a period return passes the
  # period's own length instead, which is not a presentational choice: the rate
  # for a short period expressed annually is an extrapolation, and a large one
  # is outside what Newton reaches or what a Float holds, so the annual form of
  # a few days' return is unreliable where the period form is ordinary.
  def initialize(flows, days_per_unit: DAYS_PER_YEAR)
    moves = parse(flows).reject { |flow| flow.amount.zero? }

    # The caller's own dates, captured before same-date flows are summed.
    # The duration contract is about the span handed over, and summing can
    # empty a date out entirely -- -1000 and +1000 on one day net to nothing --
    # which would otherwise turn "no time passes" into "no sign change".
    @input_dates = moves.map(&:date).uniq
    @flows = aggregate(moves)
    @days_per_unit = days_per_unit.to_f

    # Finite as well as positive: Float::INFINITY is positive, and it would make
    # every elapsed interval zero, so the present value stops depending on the
    # rate and Newton returns its starting guess of 10% as if it had solved --
    # the same trap NoDurationError exists to close.
    raise ArgumentError, "days_per_unit must be a positive, finite number of days" unless
      @days_per_unit.finite? && @days_per_unit.positive?
  end

  def self.rate(flows, days_per_unit: DAYS_PER_YEAR)
    new(flows, days_per_unit: days_per_unit).rate
  end

  # How many times the series changes sign, once zero amounts are dropped. One
  # is the ordinary shape: money goes out, money comes back.
  def sign_changes
    @sign_changes ||= flows.map { |flow| flow.amount <=> 0 }
                           .each_cons(2)
                           .count { |previous, current| previous != current }
  end

  # More than one sign change admits more than one rate (Descartes' rule bounds
  # the count by the number of changes), so the figure #rate returns is one of
  # several that fit rather than the only one. See MULTIPLE ROOTS above.
  def ambiguous?
    sign_changes > 1
  end

  # The money-weighted rate per `days_per_unit`, as a BigDecimal
  # (0.0725 == 7.25%). Annualised unless the caller said otherwise.
  def rate
    # Duration is checked first, and against the caller's dates rather than the
    # summed ones. "You gave me no time span" is prior to "money only went one
    # way": without a span no rate exists whatever the signs do. It also keeps
    # -1000 and +1000 on a single date reporting the span problem, which is the
    # useful diagnostic, rather than the empty series that summing leaves.
    raise NoDurationError, "cash flows all fall on one date" if @input_dates.one?
    raise NoSignChangeError, "cash flows never change sign" unless sign_change?

    result = newton_rate || bisection_rate
    raise ConvergenceError, "XIRR did not converge" if result.nil?

    BigDecimal(result.to_s)
  end

  # Non-raising variant for render paths: returns nil where #rate would raise.
  def self.rate_or_nil(flows, days_per_unit: DAYS_PER_YEAR)
    rate(flows, days_per_unit: days_per_unit)
  rescue NoSignChangeError, NoDurationError, ConvergenceError
    nil
  end

  private
    # Flows on the same date are summed into one, and a date whose flows net to
    # nothing drops out with the zeros.
    #
    # Summing is not a tidy-up, it is what makes the sign-change contract mean
    # anything. Two flows on one date share an exponent, so `present_value`
    # cancels them however they were written -- but `sign_changes` counts them
    # separately, and a pair that cancels looks like a sign change to it. So
    # -1000 and +1000 on one day followed by +100 passed the "money has to go
    # both ways" guard while presenting the solver with a series that is only
    # +100, has no root, and cannot be refused for the reason it should be.
    # It returned 15,118,284,881,800% rather than raising NoSignChangeError,
    # which the same series written as a single netted row does raise.
    #
    # Money in and out on one day is ordinary -- a buy and a sell, a deposit
    # spent the moment it lands -- so whether a caller pre-nets its rows is not
    # something this class should give a different answer for.
    def parse(flows)
      Array(flows).map do |flow|
        if flow.respond_to?(:date) && flow.respond_to?(:amount)
          Flow.new(date: flow.date.to_date, amount: flow.amount.to_f)
        else
          date, amount = flow
          Flow.new(date: date.to_date, amount: amount.to_f)
        end
      end
    end

    def aggregate(moves)
      moves.group_by(&:date)
           .map { |date, on_date| Flow.new(date: date, amount: on_date.sum(&:amount)) }
           .reject { |flow| flow.amount.zero? }
           .sort_by(&:date)
    end

    def sign_change?
      sign_changes.positive?
    end

    def first_date
      @first_date ||= flows.first.date
    end

    # Each flow as [units elapsed from the first flow, amount]. One unit is a
    # year unless the caller asked for a different one.
    #
    # Computed once rather than per evaluation: the intervals do not move
    # between iterations, and the two objective functions below are evaluated a
    # few hundred times per solve.
    def terms
      @terms ||= flows.map { |flow| [ (flow.date - first_date).to_i / days_per_unit, flow.amount ] }
    end

    # Present value of every flow at `rate`. The root of this is the answer.
    def present_value(rate)
      terms.sum { |units, amount| amount / ((1 + rate)**units) }
    end

    def present_value_derivative(rate)
      terms.sum do |units, amount|
        next 0.0 if units.zero?

        -units * amount / ((1 + rate)**(units + 1))
      end
    end

    # The low end of the bracket: as close to -1 as this series' arithmetic can
    # actually be evaluated, or nil if no endpoint below zero can be.
    #
    # `present_value` divides by `(1 + rate) ** units`. Near -1 that power is
    # tiny, and once it underflows to zero the quotient is Infinity -- bisection
    # sees a non-finite endpoint and abandons a series whose root is perfectly
    # ordinary. Where the underflow starts depends on the span, so a single
    # fixed floor is wrong in both directions. At -0.999999 it was too low for a
    # long series -- a 30% loss over 52 weekly units, or a 50% loss over 100
    # daily ones, both raised ConvergenceError although a rate exists and every
    # loss reaches bisection -- and needlessly high for a short one, putting a
    # near-total loss over a single year out of reach for no arithmetic reason.
    #
    # So derive it instead: start against -1 and back away until the objective
    # can be evaluated. Doubling the distance reaches any usable endpoint in at
    # most the ~52 steps it takes to cross from EPSILON to 1, and the endpoint
    # is then within a factor of two of the closest one this series admits,
    # which is ample for a bracket end. Giving up at a distance of 1 is giving
    # up at a rate of 0: a series whose amounts overflow even there has no
    # bracket to search, and nil says so rather than a fabricated figure.
    def low_endpoint
      return @low_endpoint if defined?(@low_endpoint)

      distance = NARROWEST_FLOOR_DISTANCE

      while distance < 1.0
        candidate = -1.0 + distance
        return @low_endpoint = candidate if present_value(candidate).finite?

        distance *= 2.0
      end

      @low_endpoint = nil
    end

    def newton_rate
      rate = 0.1

      MAX_NEWTON_ITERATIONS.times do
        value = present_value(rate)
        return rate if value.abs < RESIDUAL_TOLERANCE

        derivative = present_value_derivative(rate)
        return nil if derivative.zero? || !derivative.finite?

        step = value / derivative
        next_rate = rate - step

        # Newton has left the domain; hand over to bisection rather than
        # producing a NaN and calling it a return. The floor is the endpoint
        # bisection uses, so the two agree on where the domain ends instead of
        # each carrying its own idea of it.
        return nil if !next_rate.finite? || next_rate <= (low_endpoint || -1.0)

        # A step this small means Newton has stopped moving. That is NOT the
        # same as having solved: on a flat or ill-conditioned stretch it can
        # stall far from the root, and returning the rate here skipped the only
        # check that says so. Confirm the residual, and hand over to bisection
        # when it fails rather than reporting a stalled guess as an answer.
        if (next_rate - rate).abs < RATE_TOLERANCE
          return next_rate if present_value(next_rate).abs < RESIDUAL_TOLERANCE

          return nil
        end

        rate = next_rate
      end

      nil
    end

    def bisection_rate
      low = low_endpoint
      return nil if low.nil?

      high = RATE_CEILING

      low_value = present_value(low)
      high_value = present_value(high)
      return nil unless low_value.finite? && high_value.finite?

      # An endpoint can BE the root, and the sign test below cannot see it: a
      # residual of exactly zero makes the product zero, not negative, so
      # bisection walked past a solved endpoint and converged on whichever end
      # the interval collapsed towards. `[-1 today, +Float::EPSILON a year on]`
      # solves exactly at the low endpoint and returned RATE_CEILING -- a
      # 1,000,000,000% gain reported for a total loss.
      return low if low_value.abs < RESIDUAL_TOLERANCE
      return high if high_value.abs < RESIDUAL_TOLERANCE

      # The root is not inside the widest bracket we are willing to search.
      return nil if low_value * high_value > 0

      MAX_BISECTION_ITERATIONS.times do
        mid = (low + high) / 2.0
        mid_value = present_value(mid)

        return mid if mid_value.abs < RESIDUAL_TOLERANCE || (high - low).abs < RATE_TOLERANCE

        if low_value * mid_value < 0
          high = mid
        else
          low = mid
          low_value = mid_value
        end
      end

      nil
    end
end
