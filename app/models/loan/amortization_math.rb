class Loan
  # Shared per-period amortization math used by both AmortizationSchedule
  # (the original, contracted schedule) and PayoffProjection (the
  # actual-balance-based projection). Keeping this in one place means a
  # rounding/edge-case fix only needs to be made once.
  module AmortizationMath
    module_function

    # The level payment that amortises `balance` to zero over
    # `remaining_payments` periods at `monthly_rate` -- the standard annuity
    # formula, and the one figure a lender letter quotes.
    #
    # Lives here rather than on AmortizationSchedule because #15 needs the same
    # formula against a DIFFERENT principal and term: the contracted schedule
    # sizes payments from the original balance over the original term, while
    # the current minimum repayment sizes them from today's balance over the
    # term still remaining. Two callers, one formula.
    #
    # A zero rate is not a degenerate case to guard against, it is an
    # interest-free loan: the balance divided by the periods left.
    def level_payment(balance:, monthly_rate:, remaining_payments:, currency_precision:)
      return BigDecimal("0") if remaining_payments <= 0 || balance <= 0
      return (balance / remaining_payments).round(currency_precision) if monthly_rate.zero?

      growth = (1 + monthly_rate) ** remaining_payments
      ((balance * monthly_rate * growth) / (growth - 1)).round(currency_precision)
    end

    # Computes one period's interest/principal split for a fixed payment
    # amount against a given balance. Pass final: true on the period that
    # clears the loan so principal (and therefore payment_amount) is
    # adjusted to exactly zero out the balance after rounding.
    def step(balance:, payment:, monthly_rate:, currency_precision:, final: false, interest_bearing_balance: balance, interest: nil)
      interest ||= (interest_bearing_balance * monthly_rate).round(currency_precision)
      principal = final ? balance : payment - interest

      ending_balance = (balance - principal).round(currency_precision)
      ending_balance = BigDecimal(0) if ending_balance < 0

      payment_amount = final ? (principal + interest).round(currency_precision) : payment.round(currency_precision)

      {
        payment_amount: payment_amount,
        principal_payment: principal.round(currency_precision),
        interest_payment: interest.round(currency_precision),
        beginning_balance: balance.round(currency_precision),
        ending_balance: ending_balance
      }
    end
  end
end
