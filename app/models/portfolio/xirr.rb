# The internal rate of return of an irregularly-timed series of cash flows --
# the money-weighted return of a portfolio, where TWR answers what the
# investments did and this answers what the investor got.
#
# Newton-Raphson with a bisection fallback. Newton converges in a handful
# of iterations on ordinary portfolios; bisection is slower but cannot diverge,
# so it catches the pathological series -- large early withdrawals, near-zero
# terminal values -- where Newton's derivative sends it off to infinity.
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
# bracket, and two rates are then equally "the" answer. This returns whichever
# one the search reaches first. An ordinary portfolio -- money in, money out,
# a terminal value -- changes sign once and has one root, but a caller feeding
# it a series that alternates should know the figure is one of several rather
# than the only one.
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
  TOLERANCE = 1e-9

  # Widest bracket we will search. -0.999999 rather than -1 because the
  # objective function is undefined at exactly -1 (a total loss of every
  # future-dated flow). 1e7 is 1,000,000,000% -- absurd as a return, but the
  # bracket only has to contain the root, not be plausible.
  RATE_FLOOR = -0.999999
  RATE_CEILING = 1.0e7

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
    @flows = normalize(flows)
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

  # The money-weighted rate per `days_per_unit`, as a BigDecimal
  # (0.0725 == 7.25%). Annualised unless the caller said otherwise.
  def rate
    raise NoSignChangeError, "cash flows never change sign" unless sign_change?
    raise NoDurationError, "cash flows all fall on one date" if flows.map(&:date).uniq.one?

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
    def normalize(flows)
      Array(flows).map { |flow|
        if flow.respond_to?(:date) && flow.respond_to?(:amount)
          Flow.new(date: flow.date.to_date, amount: flow.amount.to_f)
        else
          date, amount = flow
          Flow.new(date: date.to_date, amount: amount.to_f)
        end
      }.reject { |flow| flow.amount.zero? }.sort_by(&:date)
    end

    def sign_change?
      flows.any? { |f| f.amount.positive? } && flows.any? { |f| f.amount.negative? }
    end

    def first_date
      @first_date ||= flows.first.date
    end

    # Units elapsed from the first flow, as a Float. One unit is a year unless
    # the caller asked for a different one.
    def units_for(flow)
      (flow.date - first_date).to_i / days_per_unit
    end

    # Present value of every flow at `rate`. The root of this is the answer.
    def present_value(rate)
      flows.sum { |flow| flow.amount / ((1 + rate)**units_for(flow)) }
    end

    def present_value_derivative(rate)
      flows.sum do |flow|
        units = units_for(flow)
        next 0.0 if units.zero?

        -units * flow.amount / ((1 + rate)**(units + 1))
      end
    end

    def newton_rate
      rate = 0.1

      MAX_NEWTON_ITERATIONS.times do
        value = present_value(rate)
        return rate if value.abs < TOLERANCE

        derivative = present_value_derivative(rate)
        return nil if derivative.zero? || !derivative.finite?

        step = value / derivative
        next_rate = rate - step

        # Newton has left the domain; hand over to bisection rather than
        # producing a NaN and calling it a return.
        return nil if next_rate <= RATE_FLOOR || !next_rate.finite?

        # A step this small means Newton has stopped moving. That is NOT the
        # same as having solved: on a flat or ill-conditioned stretch it can
        # stall far from the root, and returning the rate here skipped the only
        # check that says so. Confirm the residual, and hand over to bisection
        # when it fails rather than reporting a stalled guess as an answer.
        if (next_rate - rate).abs < TOLERANCE
          return next_rate if present_value(next_rate).abs < TOLERANCE

          return nil
        end

        rate = next_rate
      end

      nil
    end

    def bisection_rate
      low = RATE_FLOOR
      high = RATE_CEILING

      low_value = present_value(low)
      high_value = present_value(high)
      return nil unless low_value.finite? && high_value.finite?
      # The root is not inside the widest bracket we are willing to search.
      return nil if low_value * high_value > 0

      MAX_BISECTION_ITERATIONS.times do
        mid = (low + high) / 2.0
        mid_value = present_value(mid)

        return mid if mid_value.abs < TOLERANCE || (high - low).abs < TOLERANCE

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
