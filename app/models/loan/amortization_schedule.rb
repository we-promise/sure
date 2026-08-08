# Builds a constant-payment ("French") amortization schedule for a fixed-rate loan.
#
# Each period charges interest on the outstanding principal and applies the
# remainder of the fixed payment to principal, so the principal/interest split
# shifts over the life of the loan. This is the standard system for European
# mortgages and for most US fixed-rate loans.
#
# All arithmetic runs in BigDecimal and every payment is rounded to the
# currency's precision, exactly as a lender's own table does. The final payment
# absorbs whatever rounding residue is left so the balance lands on zero.
class Loan::AmortizationSchedule
  Payment = Data.define(:number, :date, :payment, :principal, :interest, :ending_balance)

  attr_reader :principal, :annual_rate, :term_months, :start_date, :currency

  class << self
    # Returns a schedule for the loan, or nil when the loan isn't amortizable
    # (variable rate, or missing rate/term/principal).
    def for(loan)
      return nil unless loan.amortizable?

      new(
        principal: loan.original_balance.amount,
        annual_rate: loan.interest_rate,
        term_months: loan.term_months,
        start_date: loan.origination_date,
        currency: loan.account.currency
      )
    end
  end

  def initialize(principal:, annual_rate:, term_months:, start_date:, currency:)
    @principal = BigDecimal(principal.to_s)
    @annual_rate = BigDecimal(annual_rate.to_s)
    @term_months = term_months.to_i
    @start_date = start_date
    @currency = currency
  end

  def payments
    @payments ||= build_payments
  end

  # The level payment charged every period. The last payment can differ by a
  # few cents — read it off #payments when the exact figure matters.
  def periodic_payment
    return money(0) unless schedulable?

    money(raw_periodic_payment)
  end

  def total_interest
    money(payments.sum(BigDecimal(0)) { |payment| payment.interest.amount })
  end

  def total_paid
    money(payments.sum(BigDecimal(0)) { |payment| payment.payment.amount })
  end

  def payoff_date
    payments.last&.date
  end

  # The scheduled payment falling in the same calendar month as `date`, if any.
  # Callers use this to reconcile a real bank payment against the schedule.
  def payment_for(date)
    payments.find { |payment| payment.date.year == date.year && payment.date.month == date.month }
  end

  private
    def monthly_rate
      @monthly_rate ||= annual_rate / 100 / 12
    end

    # P·i·(1+i)^n / ((1+i)^n − 1), degrading to straight-line for a 0% loan.
    def raw_periodic_payment
      @raw_periodic_payment ||= begin
        if monthly_rate.zero?
          round_to_currency(principal / term_months)
        else
          growth = (1 + monthly_rate)**term_months
          round_to_currency(principal * monthly_rate * growth / (growth - 1))
        end
      end
    end

    def build_payments
      return [] unless schedulable?

      balance = principal
      level_payment = raw_periodic_payment
      built = []

      (1..term_months).each do |number|
        # Rounding can make the level payment slightly over-cover the loan, so
        # the balance can reach zero before the nominal term is up. Stop, and
        # keep the periods built so far.
        break if balance <= 0

        interest = round_to_currency(balance * monthly_rate)
        principal_portion = level_payment - interest

        # Final period, or a payment large enough to clear the balance: settle
        # the remaining principal exactly rather than leaving rounding dust.
        if number == term_months || principal_portion >= balance
          principal_portion = balance
        end

        balance -= principal_portion

        built << Payment.new(
          number: number,
          date: start_date >> number,
          payment: money(principal_portion + interest),
          principal: money(principal_portion),
          interest: money(interest),
          ending_balance: money(balance)
        )
      end

      built
    end

    def schedulable?
      term_months.positive? && principal.positive?
    end

    def round_to_currency(value)
      value.round(currency_precision)
    end

    def currency_precision
      @currency_precision ||= Money::Currency.new(currency).default_precision || 2
    end

    def money(value)
      Money.new(value, currency)
    end
end
