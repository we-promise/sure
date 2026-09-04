class Loan
  # Shared per-period amortization math used by both AmortizationSchedule
  # (the original, contracted schedule) and PayoffProjection (the
  # actual-balance-based projection). Keeping this in one place means a
  # rounding/edge-case fix only needs to be made once.
  module AmortizationMath
    module_function

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
