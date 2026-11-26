# Builds a constant-payment ("French") amortisation schedule for a loan.
#
# Each period charges interest on the outstanding principal and applies the
# remainder of the level payment to principal, so the principal/interest split
# shifts over the life of the loan. This is the standard system for European
# mortgages and for most US fixed-rate loans.
#
# All arithmetic runs in BigDecimal and every payment is rounded to the
# currency's precision, exactly as a lender's own table does. The final payment
# absorbs whatever rounding residue is left so the balance lands on zero.
#
# The period-by-period walk itself lives in Loan::Simulator. This class owns
# what a *schedule* is -- the dates, the term, and the presentation of a run as
# Payment records -- and nothing about how interest accrues.
class Loan::AmortizationSchedule
  Payment = Data.define(:number, :date, :payment, :principal, :interest, :ending_balance)

  attr_reader :principal, :annual_rate, :term_months, :start_date, :currency

  class << self
    # Returns a schedule for the loan, or nil when the loan isn't amortizable
    # (missing rate/term/principal).
    def for(loan)
      return nil unless loan.amortizable?

      # A contracted payment or a balloon is a fixed-rate concept -- the
      # model requires an explicit fixed rate, and other loans never read them.
      fixed_rate = loan.rate_type == Loan::FIXED_RATE_TYPE

      new(
        principal: loan.original_balance.amount,
        annual_rate: loan.interest_rate,
        term_months: loan.term_months,
        start_date: loan.origination_date,
        currency: loan.account.currency,
        rate_resolver: (Loan::RateResolver.for(loan) if loan.variable_rate_type?),
        day_count_convention: loan.day_count_convention,
        contracted_payment: (loan.contracted_payment if fixed_rate),
        balloon_payment: (loan.balloon_payment if fixed_rate)
      )
    end
  end

  # `rate_resolver` is how a variable loan's recorded rate changes reach the
  # simulator. Omitted, the schedule runs at one rate for its whole life, which
  # is what a fixed loan does.
  def initialize(principal:, annual_rate:, term_months:, start_date:, currency:, rate_resolver: nil,
                 day_count_convention: Loan::Simulator::DEFAULT_DAY_COUNT_CONVENTION,
                 contracted_payment: nil, balloon_payment: nil)
    @currency = currency
    # Rounded to the currency at the door. A balance carrying more fractional
    # units than the currency has -- `first_valuation_amount` is decimal(19,4)
    # against two-decimal USD -- otherwise loses its residue in the first
    # period's rounding, and the principal portions then sum to less than the
    # loan. A schedule is denominated in its currency; sub-unit precision in
    # the opening balance is not a thing it can represent.
    @principal = BigDecimal(principal.to_s).round(currency_precision)
    @annual_rate = BigDecimal(annual_rate.to_s)
    @term_months = term_months.to_i
    @start_date = start_date
    @rate_resolver = rate_resolver
    @day_count_convention = day_count_convention
    @contracted_payment = contracted_payment && BigDecimal(contracted_payment.to_s).round(currency_precision)
    @balloon_payment = balloon_payment && BigDecimal(balloon_payment.to_s).round(currency_precision)
  end

  # True when this schedule re-amortises part-way through, i.e. the repayment
  # is re-sized at some payment after the first. Views use it to decide whether
  # "the monthly payment" is a meaningful thing to say. Asked of the run rather
  # than of the recorded changes: a change to the same rate, or one effective
  # on the first payment, is an event that moves nothing in-term, and a
  # constant payment must not be labelled an opening one.
  def re_amortising?
    return false unless @rate_resolver
    return false unless schedulable?

    simulation.payments.each_cons(2).any? { |previous, current| previous[:sizing_rate] != current[:sizing_rate] }
  end

  # Every scheduled payment, oldest first. Empty when there is nothing to
  # amortise; shorter than the term when rounding clears the balance early.
  def payments
    @payments ||= simulation.payments.map do |row|
      Payment.new(
        number: row[:payment_number],
        date: row[:payment_date],
        payment: money(row[:payment_amount]),
        principal: money(row[:principal_payment]),
        interest: money(row[:interest_payment]),
        ending_balance: money(row[:ending_balance])
      )
    end
  end

  # The level payment the schedule opens with. The last payment can differ by
  # a few cents, and on a re-amortising loan every payment after a rate change
  # differs too -- read them off #payments when the exact figures matter, and
  # see #re_amortising? before presenting this as "the" monthly payment.
  def periodic_payment
    # Read off the first simulated payment rather than re-deriving it from the
    # base rate. A rate change effective ON the first payment date already
    # sizes that payment, and re-deriving would quote the rate the loan was
    # written at for a payment the borrower will never make. For a fixed loan
    # the two are the same number.
    payments.first&.payment || money(0)
  end

  # What the loan costs in interest over its whole life. Sits slightly above
  # the naive periodic_payment * term figure because interest is rounded to
  # the currency's precision every period.
  def total_interest
    money(simulation.total_interest)
  end

  # Principal plus total_interest -- everything the borrower pays.
  def total_paid
    money(payments.sum(BigDecimal("0")) { |payment| payment.payment.amount })
  end

  # The date of the final payment, or nil when there's nothing to amortise.
  def payoff_date
    payments.last&.date
  end

  def final_balloon_adjustment
    return unless @balloon_payment

    simulation.payments.last&.[](:balloon_adjustment)
  end

  # The scheduled payment falling in the same calendar month as `date`, if any.
  # Callers use this to reconcile a real bank payment against the schedule.
  def payment_for(date)
    payments.find { |payment| payment.date.year == date.year && payment.date.month == date.month }
  end

  # The repayment in force on `as_of`: the next scheduled payment on or after
  # it, sized at every rate change recorded before that payment. A variable
  # loan has no single monthly payment, but it always has this one. Nil once
  # the schedule has run out.
  def payment_in_force(as_of)
    payments.find { |payment| payment.date >= as_of }&.payment
  end

  private
    # One payment per month of the term, stepping from origination. `>>` gives
    # the calendar-correct answer at month ends: 31 January plus one month is
    # 28 February, not 3 March.
    def payment_schedule
      @payment_schedule ||= (1..term_months).map { |number| start_date >> number }
    end

    # The simulator refuses an empty schedule rather than inventing a
    # degenerate run, so a loan with nothing to amortise is answered here.
    def simulation
      @simulation ||= if schedulable?
        Loan::Simulator.new(**simulator_options, **contracted_terms).run
      else
        Loan::SimulationResult.new(payments: [], currency_precision: currency_precision)
      end
    end

    # Everything a run needs except the contracted terms, factored out so the
    # balloon sizing probes below run the same simulator the schedule does.
    def simulator_options
      {
        starting_balance: principal,
        accrual_start_date: start_date,
        payment_schedule: payment_schedule,
        accrual_rate_for: @rate_resolver ? @rate_resolver.method(:accrual_rate_for) : ->(_date) { annual_rate },
        re_amortisation_events: @rate_resolver&.method(:re_amortisation_events),
        currency_precision: currency_precision,
        day_count_convention: @day_count_convention
      }
    end

    # The simulator arguments a lender's own figures imply. With neither a
    # contracted payment nor a balloon there is nothing to hold or replace,
    # so this is empty and the call above stays exactly the default run.
    # With either, the instalment is held: the recorded one, or the level
    # payment sized so the last instalment lands on the balloon. A balloon
    # also replaces the final row with the quoted figure rather than the
    # settlement the run would compute -- but only when it covers that row's
    # balance plus interest, so the instalment must be sized to guarantee it.
    def contracted_terms
      return {} if @contracted_payment.nil? && @balloon_payment.nil?

      {
        payment_strategy: :hold,
        payment_amount: @contracted_payment || balloon_level_payment,
        final_payment: @balloon_payment
      }
    end

    # The instalment of a balloon-only loan, sized so the last row's real
    # cost -- balance plus the period's accrued interest -- is not above the
    # balloon. The closed formula only seeds the figure: it assumes a flat
    # twelfth and exact arithmetic, so per-period rounding and a day-count
    # convention can leave the last date's settlement cents or hundreds above
    # the balloon, and a balloon that short is ignored. The correction is
    # therefore measured against the schedule itself.
    def balloon_level_payment
      seed = Loan::AmortizationMath.balloon_level_payment(
        balance: principal,
        monthly_rate: Loan::AmortizationMath.monthly_rate(annual_rate),
        payments: term_months,
        balloon: @balloon_payment,
        currency_precision: currency_precision
      )
      return nil if seed.nil?

      rows0, needed0 = settlement_needed(seed)
      rows1, needed1 = settlement_needed(seed + 1)
      slope = needed0 - needed1

      return seed if rows0 < term_months
      if rows1 < term_months
        return seed if needed0 <= @balloon_payment

        return balloon_payment_between(seed, seed + 1)
      end
      return seed if slope <= 0

      instalment = [ (seed + (needed0 - @balloon_payment) / slope).ceil(currency_precision), BigDecimal("0") ].max

      # The linear estimate can still land a minor unit short when `needed`
      # is not quite linear; walk up until the balloon provably covers.
      minor_unit = BigDecimal(10)**-currency_precision
      5.times do
        _rows, needed = settlement_needed(instalment)
        break if needed <= @balloon_payment
        instalment += minor_unit
      end

      instalment
    end

    def balloon_payment_between(seed, upper_bound)
      units = 10**currency_precision
      first_covering = ((seed * units).to_i + 1..(upper_bound * units).to_i).bsearch do |amount|
        rows, needed = settlement_needed(BigDecimal(amount) / units)
        rows < term_months || needed <= @balloon_payment
      end
      instalment = BigDecimal(first_covering) / units
      rows, = settlement_needed(instalment)
      rows == term_months ? instalment : seed
    end

    # What the last scheduled instalment must cover at a given held
    # instalment: with settle_at_schedule_end the final row's payment_amount
    # is the balance plus the period's accrued interest. Probing runs the
    # same simulator as the schedule itself, minus the contracted terms, so
    # the two cannot drift.
    def settlement_needed(instalment)
      rows = Loan::Simulator.new(
        **simulator_options,
        payment_strategy: :hold,
        payment_amount: instalment
      ).run.payments

      [ rows.length, rows.last[:payment_amount] ]
    end

    def schedulable?
      term_months.positive? && principal.positive?
    end

    def currency_precision
      @currency_precision ||= Money::Currency.new(currency).default_precision || 2
    end

    def money(value)
      Money.new(value, currency)
    end
end
