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

      new(
        principal: loan.original_balance.amount,
        annual_rate: loan.interest_rate,
        term_months: loan.term_months,
        start_date: loan.origination_date,
        currency: loan.account.currency,
        rate_resolver: (Loan::RateResolver.for(loan) if loan.variable_rate_type?)
      )
    end
  end

  # `rate_resolver` is how a variable loan's recorded rate changes reach the
  # simulator. Omitted, the schedule runs at one rate for its whole life, which
  # is what a fixed loan does.
  def initialize(principal:, annual_rate:, term_months:, start_date:, currency:, rate_resolver: nil)
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

  # The scheduled payment falling in the same calendar month as `date`, if any.
  # Callers use this to reconcile a real bank payment against the schedule.
  def payment_for(date)
    payments.find { |payment| payment.date.year == date.year && payment.date.month == date.month }
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
        Loan::Simulator.new(
          starting_balance: principal,
          accrual_start_date: start_date,
          payment_schedule: payment_schedule,
          accrual_rate_for: @rate_resolver ? @rate_resolver.method(:accrual_rate_for) : ->(_date) { annual_rate },
          re_amortisation_events: @rate_resolver&.method(:re_amortisation_events),
          currency_precision: currency_precision
        ).run
      else
        Loan::SimulationResult.new(payments: [], currency_precision: currency_precision)
      end
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
