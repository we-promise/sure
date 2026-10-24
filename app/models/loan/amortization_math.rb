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

    module_function

    # `annual_percentage` is whatever the caller's rate source returned -- an
    # Integer in tests, a BigDecimal from RateResolver -- so the coercion at
    # this boundary stays. The two-step division is kept so results match the
    # schedules this product has always produced.
    def monthly_rate(annual_percentage)
      (BigDecimal(annual_percentage.to_s) / PERCENT) / MONTHS_PER_YEAR
    end

    # How much of a year one period charges, under the loan's day-count
    # convention. 30/360 is a flat twelfth, which is why it keeps the original
    # schedule bit-identical.
    def accrual_factor(annual_percentage:, period_start:, period_end:, day_count_convention:)
      return monthly_rate(annual_percentage) if day_count_convention.to_sym == :thirty_360

      if period_end < period_start
        raise ArgumentError, "period ends (#{period_end}) before it starts (#{period_start})"
      end

      rate = BigDecimal(annual_percentage.to_s) / PERCENT

      if day_count_convention.to_sym == :actual_365
        return (rate * BigDecimal((period_end - period_start).to_i.to_s)) / DAYS_PER_YEAR
      end

      rate * actual_actual_year_fraction(period_start, period_end)
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
