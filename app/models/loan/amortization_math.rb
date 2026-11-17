require "bigdecimal/math"

class Loan
  # Shared per-period amortisation math. Kept in one place so a rounding or
  # edge-case fix only has to be made once: the contracted schedule sizes
  # payments from the original balance over the original term, and a
  # re-amortisation part-way through sizes them from the balance then
  # outstanding over the periods still remaining. Two callers, one formula.
  module AmortizationMath
    PERCENT = BigDecimal("100")
    MONTHS_PER_YEAR = BigDecimal("12")
    DAYS_PER_YEAR = BigDecimal("365")
    DAYS_PER_LEAP_YEAR = BigDecimal("366")

    # How often the stated annual rate compounds.
    #
    # `per_period` is the default because it IS what this engine has always
    # charged: the annual rate divided by twelve for a month, or by the day
    # count for a part of one. Every loan that does not choose a compounding
    # keeps its schedule row for row.
    #
    # `semi_annual` and `annual` are for contracts that state the rate
    # compounded half-yearly or yearly. Canadian fixed-rate mortgages are the
    # common case: the Interest Act requires the rate to be stated "calculated
    # yearly or half-yearly, not in advance", and lenders use half-yearly. A
    # period of `t` years then charges `(1 + r/m)^(m * t) - 1`, with `m`
    # compoundings a year, instead of `r * t`.
    COMPOUNDINGS = %i[per_period semi_annual annual].freeze
    DEFAULT_COMPOUNDING = :per_period
    COMPOUNDINGS_PER_YEAR = { semi_annual: 2, annual: 1 }.freeze

    # Significant digits for the fractional powers below. A period's factor is
    # multiplied by a balance and rounded to the currency, so thirty digits
    # leave the cent untouched on any balance a loan can hold.
    COMPOUNDING_PRECISION = 30

    module_function

    # The rate for one twelfth of a year: what a month charges under 30/360,
    # and what the payment is sized at.
    #
    # `annual_percentage` is whatever the caller's rate source returned -- an
    # Integer in tests, a BigDecimal from RateResolver -- so the coercion at
    # this boundary stays. The two-step division is kept so results match the
    # schedules this product has always produced.
    def monthly_rate(annual_percentage, compounding: DEFAULT_COMPOUNDING)
      return (BigDecimal(annual_percentage.to_s) / PERCENT) / MONTHS_PER_YEAR if per_period?(compounding)

      compounded_rate(annual_percentage, compounding, BigDecimal("1") / MONTHS_PER_YEAR)
    end

    # How much of a year one period charges, under the loan's day-count
    # convention and compounding.
    #
    # Under 30/360 a full scheduled period is a flat twelfth. A period cut
    # short by a valuation is not a full month, so it charges its own 30/360
    # days. `full_period` keeps the contracted schedule bit-identical while
    # letting a partial period charge the days it actually covers.
    #
    # The day count measures the period; the compounding turns that measure
    # into a charge. A full 30/360 period returns `monthly_rate` itself, so a
    # loan on the default day count charges exactly what its payment was sized
    # at, whatever its compounding.
    def accrual_factor(annual_percentage:, period_start:, period_end:, day_count_convention:, full_period: true,
                       compounding: DEFAULT_COMPOUNDING)
      if period_end < period_start
        raise ArgumentError, "period ends (#{period_end}) before it starts (#{period_start})"
      end

      convention = day_count_convention.to_sym
      if convention == :thirty_360 && full_period
        return monthly_rate(annual_percentage, compounding: compounding)
      end

      unless per_period?(compounding)
        return compounded_rate(annual_percentage, compounding, year_fraction(convention, period_start, period_end))
      end

      rate = BigDecimal(annual_percentage.to_s) / PERCENT

      return rate * thirty_360_year_fraction(period_start, period_end) if convention == :thirty_360

      if convention == :actual_365
        return (rate * BigDecimal((period_end - period_start).to_i.to_s)) / DAYS_PER_YEAR
      end

      rate * actual_actual_year_fraction(period_start, period_end)
    end

    # The share of a year between two dates, under a day-count convention.
    def year_fraction(day_count_convention, period_start, period_end)
      case day_count_convention.to_sym
      when :thirty_360 then thirty_360_year_fraction(period_start, period_end)
      when :actual_365 then BigDecimal((period_end - period_start).to_i.to_s) / DAYS_PER_YEAR
      else actual_actual_year_fraction(period_start, period_end)
      end
    end

    # `(1 + r/m)^(m * years) - 1`: what a balance grows by over `years` when
    # the annual rate `r` compounds `m` times a year. A zero rate or a period
    # of no length charges nothing, and skips the logarithm.
    def compounded_rate(annual_percentage, compounding, years)
      per_year = COMPOUNDINGS_PER_YEAR.fetch(compounding.to_sym) do
        raise ArgumentError, "unsupported compounding: #{compounding.inspect} (expected one of #{COMPOUNDINGS.join(', ')})"
      end
      rate = BigDecimal(annual_percentage.to_s) / PERCENT
      return BigDecimal("0") if rate.zero? || years.zero?

      base = 1 + rate / per_year
      BigMath.exp(BigMath.log(base, COMPOUNDING_PRECISION) * (per_year * years), COMPOUNDING_PRECISION) - 1
    end

    def per_period?(compounding)
      compounding.nil? || compounding.to_sym == :per_period
    end

    # US 30/360 day fraction for a part-month period. The month-end rules keep
    # the common cases consistent: a 31st start counts as the 30th, and a 31st
    # end does too when the start is already the 30th.
    def thirty_360_year_fraction(period_start, period_end)
      start_day = period_start.day
      end_day = period_end.day
      start_day = 30 if start_day == 31
      end_day = 30 if end_day == 31 && start_day == 30

      days = 360 * (period_end.year - period_start.year) +
             30 * (period_end.month - period_start.month) +
             (end_day - start_day)

      BigDecimal(days.to_s) / 360
    end

    # actual/actual measures each calendar year's days against THAT year's own
    # length, so a period crossing New Year is two fractions rather than one.
    def actual_actual_year_fraction(period_start, period_end)
      fraction = BigDecimal("0")
      cursor = period_start

      while cursor < period_end
        next_year_start = Date.new(cursor.year + 1, 1, 1)
        segment_end = [ next_year_start, period_end ].min
        days = BigDecimal((segment_end - cursor).to_i.to_s)
        denominator = Date.leap?(cursor.year) ? DAYS_PER_LEAP_YEAR : DAYS_PER_YEAR

        fraction += days / denominator
        cursor = segment_end
      end

      fraction
    end

    # The level payment that amortises `balance` to zero over
    # `remaining_payments` periods at `monthly_rate` -- the standard annuity
    # formula, and the figure a lender quotes.
    #
    # A zero rate is not a degenerate case to guard against, it is an
    # interest-free loan: the balance divided by the periods left.
    #
    # `first_period_interest` is for a resize on a rate change: the period
    # that closes on the change accrued at the OLD rate, and the annuity
    # formula assumes every remaining period, this one included, accrues at
    # `monthly_rate`. Sized that way the payment over-covers the first period
    # and the final settlement becomes a discount of thousands. Given the
    # interest actually charged this period, the figure returned is the one
    # payment that covers it and then amortises what is left over the
    # remaining periods at `monthly_rate` -- level to maturity. With the
    # interest at `monthly_rate` the two formulas agree exactly, so the plain
    # one is kept for the common case and stays bit-identical.
    def level_payment(balance:, monthly_rate:, remaining_payments:, currency_precision:, first_period_interest: nil)
      return BigDecimal("0") if remaining_payments <= 0 || balance <= 0

      if first_period_interest
        later = remaining_payments - 1
        annuity = if later.zero?
          BigDecimal("0")
        elsif monthly_rate.zero?
          BigDecimal(later)
        else
          later_growth = (1 + monthly_rate)**later
          (later_growth - 1) / (monthly_rate * later_growth)
        end
        return ((balance + first_period_interest) / (1 + annuity)).round(currency_precision)
      end

      return (balance / remaining_payments).round(currency_precision) if monthly_rate.zero?

      growth = (1 + monthly_rate)**remaining_payments
      ((balance * monthly_rate * growth) / (growth - 1)).round(currency_precision)
    end

    # One period's interest/principal split for a fixed payment against a given
    # balance.
    #
    # `final: true` settles the remaining principal exactly rather than leaving
    # rounding dust, and re-derives the payment from it -- so the last payment
    # of a schedule can differ from the level payment by a few cents, exactly as
    # a lender's own table does.
    def step(balance:, payment:, monthly_rate:, currency_precision:, final: false, interest: nil)
      interest ||= (balance * monthly_rate).round(currency_precision)
      principal = final ? balance : payment - interest

      ending_balance = (balance - principal).round(currency_precision)
      ending_balance = BigDecimal("0") if ending_balance.negative?

      {
        payment_amount: final ? (principal + interest).round(currency_precision) : payment.round(currency_precision),
        principal_payment: principal.round(currency_precision),
        interest_payment: interest.round(currency_precision),
        beginning_balance: balance.round(currency_precision),
        ending_balance: ending_balance
      }
    end
  end
end
