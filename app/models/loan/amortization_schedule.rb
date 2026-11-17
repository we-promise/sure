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
        rate_resolver: (Loan::RateResolver.for(loan) if loan.variable_rate_type?),
        day_count_convention: loan.day_count_convention,
        term_changes: loan.active_term_changes.map(&:to_schedule_change)
      )
    end
  end

  # `rate_resolver` is how a variable loan's recorded rate changes reach the
  # simulator. Omitted, the schedule runs at one rate for its whole life, which
  # is what a fixed loan does.
  #
  # `term_changes` are the recorded changes to the contract, in the shape the
  # simulator takes. The schedule follows them, so it stays the lender's own
  # table after an extra repayment or a new instalment.
  def initialize(principal:, annual_rate:, term_months:, start_date:, currency:, rate_resolver: nil,
                 day_count_convention: Loan::Simulator::DEFAULT_DAY_COUNT_CONVENTION, term_changes: [])
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
    @term_changes = term_changes
  end

  # True when this schedule re-amortises part-way through, i.e. the repayment
  # is re-sized at some payment after the first. Views use it to decide whether
  # "the monthly payment" is a meaningful thing to say. Asked of the run rather
  # than of the recorded changes: a change to the same rate, or one effective
  # on the first payment, is an event that moves nothing in-term, and a
  # constant payment must not be labelled an opening one.
  #
  # A term change counts when it moves the payment: an extra repayment the
  # lender answered with a lower instalment does, one the borrower keeps paying
  # the old instalment through does not. The last row is left out of that
  # comparison, because it settles whatever is left.
  def re_amortising?
    return false unless schedulable?

    rows = simulation.payments
    rate_moved = @rate_resolver.present? &&
      rows.each_cons(2).any? { |previous, current| previous[:sizing_rate] != current[:sizing_rate] }

    rate_moved || (@term_changes.any? &&
      rows[0...-1].each_cons(2).any? { |previous, current| previous[:payment_amount] != current[:payment_amount] })
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

  # Principal plus total_interest -- everything the borrower pays. What a term
  # change took off the balance (an extra repayment, or a confirmed balance
  # below the schedule's) was paid outside the instalments, so it is added
  # here. A confirmed balance above the schedule's is not a payment and is
  # left out; the instalments after it repay it. Nor does it offset a
  # repayment recorded in the same period, which is why the rows' net
  # adjustments are not what is summed.
  def total_paid
    repaid_outside_payments = row_figures(:repaid_outside_payment).values.sum(BigDecimal("0"), &:amount)

    money(payments.sum(BigDecimal("0")) { |payment| payment.payment.amount } + repaid_outside_payments)
  end

  # What recorded term changes moved the balance by on a payment's row, on top
  # of the principal the payment repaid: negative for an extra repayment,
  # either sign for a balance the lender confirmed. Nil for a row they left
  # alone.
  def balance_adjustment_for(payment)
    balance_adjustments[payment.number]
  end

  # The part of a row's extra repayments made after the period's interest was
  # charged and before the payment date: later than the grace days. In the
  # ledger replay such a transfer pays that interest first. Nil for a row
  # without one.
  def repaid_after_charge_for(payment)
    row_figures(:repaid_after_charge)[payment.number]
  end

  # Whether a payment the lender set falls short of the interest of a period
  # it is in force for, the final one included. Only those rows are read: on
  # a long loan at a high rate under an actual day count, the level payment
  # itself can fall a little short in a 31-day period.
  def lender_payment_below_interest?
    simulation.payments.any? { |row| row[:lender_payment_below_interest] }
  end

  # The share of its balance the period of a payment charged as interest,
  # when a term change is dated in that period. It carries the rate, the day
  # count and, after a confirmed balance part-way through, the shorter
  # period. Nil for a period without a term change.
  def interest_factor_for(payment)
    simulation.payments[payment.number - 1]&.dig(:accrual_factor)
  end

  # The date of the final payment. Nil when there's nothing to amortise, or
  # when a balance the lender confirmed for the last payment date leaves the
  # loan owing. The loan form refuses such a row; one stored before the term
  # was shortened can still give it.
  def payoff_date
    simulation.payoff_date
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

    def balance_adjustments
      row_figures(:balance_adjustment)
    end

    # A figure only the rows a term change touched carry, by payment number.
    def row_figures(key)
      @row_figures ||= {}
      @row_figures[key] ||= simulation.payments.each_with_object({}) do |row, figures|
        figures[row[:payment_number]] = money(row[key]) if row.key?(key)
      end
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
          currency_precision: currency_precision,
          day_count_convention: @day_count_convention,
          term_changes: @term_changes,
          # The replay's window, so the schedule and the replay agree on which
          # period an extra repayment a few days after a due date belongs to.
          payment_grace_days: Loan::PrincipalPayments::PAYMENT_GRACE_DAYS
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
