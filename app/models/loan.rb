class Loan < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "mortgage" => { short: "Mortgage", long: "Mortgage" },
    "student" => { short: "Student Loan", long: "Student Loan" },
    "auto" => { short: "Auto Loan", long: "Auto Loan" },
    "home_equity" => { short: "Home Equity", long: "Home Equity Loan" },
    "line_of_credit" => { short: "Line of Credit", long: "Line of Credit" },
    "business" => { short: "Business Loan", long: "Business Loan" },
    "other" => { short: "Other Loan", long: "Other Loan" }
  }.freeze

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true

  def monthly_payment
    return nil if term_months.nil? || interest_rate.nil? || rate_type.nil? || rate_type != "fixed"
    return Money.new(0, account.currency) if account.loan.original_balance.amount.zero? || term_months.zero?

    annual_rate = interest_rate / 100.0
    monthly_rate = annual_rate / 12.0

    if monthly_rate.zero?
      payment = account.loan.original_balance.amount / term_months
    else
      payment = (account.loan.original_balance.amount * monthly_rate * (1 + monthly_rate)**term_months) / ((1 + monthly_rate)**term_months - 1)
    end

    Money.new(payment.round, account.currency)
  end

  def original_balance
    Money.new(account.first_valuation_amount, account.currency)
  end

  # Drives whether the contract-details disclosure opens by default on the form.
  def contract_terms?
    [ origination_date, maturity_date, apr, insurance_monthly_amount,
      scheduled_payment, early_repayment_terms ].any?(&:present?)
  end

  # What is actually debited each month. `monthly_payment` only exists for a
  # fixed-rate loan, so a hand-entered `scheduled_payment` takes precedence and
  # is the only figure available for a variable or adjustable rate.
  def effective_payment
    return Money.new(scheduled_payment, account.currency) if scheduled_payment.present?

    monthly_payment
  end

  # The instalment plus the borrower's insurance premium. The premium is billed
  # alongside the loan but sits outside the amortization schedule, so quoting
  # the instalment alone understates the real monthly burden.
  def total_monthly_cost
    payment = effective_payment
    return nil if payment.nil?

    return payment if insurance_monthly_amount.blank?

    payment + Money.new(insurance_monthly_amount, account.currency)
  end

  # Number of instalments still to run, from the live balance rather than from
  # term_months, so an overpayment or a missed month is reflected.
  #
  # Derived from the amortization identity B = P * (1 - (1+r)^-n) / r, solved
  # for n. Returns nil when the inputs cannot support an answer, never a
  # plausible-looking guess.
  def remaining_payments
    # Balance first: a cleared loan has no payments left whatever the
    # instalment is, and Loan#monthly_payment returns zero once the original
    # balance is zero, which would otherwise read as "not computable".
    balance = account.balance.to_d
    return 0 if balance <= 0

    payment = effective_payment&.amount
    return nil if payment.nil? || payment <= 0

    rate = monthly_rate
    # An unknown rate is not a zero rate. Dividing the balance by the instalment
    # would quote the payoff count of an interest-free loan, which is always too
    # short and reads as authoritative. A declared 0% is a real rate and does
    # take that branch.
    return nil if rate.nil?
    return (balance / payment).ceil if rate.zero?

    interest_due = balance * rate
    # A payment that does not even cover one month of interest never clears the
    # principal. Saying so is the honest answer; any number here would be a lie.
    return nil if payment <= interest_due

    (-Math.log(1 - (interest_due / payment).to_f) / Math.log(1 + rate.to_f)).ceil
  end

  # The stored maturity date wins when the user entered one: it is the contract.
  # Otherwise it is projected from the instalments still to run.
  def payoff_date
    return maturity_date if maturity_date.present?

    remaining = remaining_payments
    return nil if remaining.nil?

    Date.current.advance(months: remaining)
  end

  # Interest still to be paid if the loan runs to term at the current payment.
  # Insurance is excluded: it is a premium, not interest.
  def remaining_interest
    remaining = remaining_payments
    payment = effective_payment
    return nil if remaining.nil? || payment.nil?
    return Money.new(0, account.currency) if remaining.zero?

    balance = account.balance.to_d
    total = payment.amount * (remaining - 1) + final_installment(balance, payment.amount, remaining)

    Money.new([ total - balance, 0 ].max, account.currency)
  end

  class << self
    def color
      "#D444F1"
    end

    def icon
      "hand-coins"
    end

    def classification
      "liability"
    end
  end

  private
    # The last instalment settles whatever is left; it is not another full
    # payment. Counting a full one invents interest that a 0% loan cannot
    # charge: 1,201 repaid in instalments of 12 ends on a 1, not on a 12, and
    # that 11 was being reported as interest still owed.
    def final_installment(balance, payment, remaining)
      rate = monthly_rate

      return [ balance - payment * (remaining - 1), 0.to_d ].max if rate.zero?

      # Balance after the first `remaining - 1` full payments, from the same
      # amortization identity `remaining_payments` inverts, plus the month of
      # interest the final payment still carries.
      growth = (1 + rate) ** (remaining - 1)
      outstanding = balance * growth - payment * (growth - 1) / rate

      [ outstanding * (1 + rate), 0.to_d ].max
    end

    # interest_rate is the NOMINAL annual rate. `apr` is deliberately not used
    # here: a French TAEG bundles fees and insurance, and feeding it to the
    # amortization formula would overstate the interest every month.
    def monthly_rate
      return nil if interest_rate.nil?

      interest_rate.to_d / 100 / 12
    end
end
