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

  # Standard amortizing loans accrue interest monthly.
  PAYMENT_PERIODS_PER_YEAR = 12

  # True when payments linked to this loan should be automatically split into
  # a principal portion (which reduces the loan balance via a transfer) and an
  # interest portion (recorded as an expense). Requires a usable interest rate.
  def splits_payments?
    auto_split_payments? && interest_rate.present? && interest_rate.to_d.positive?
  end

  # Interest portion of a single payment, computed from the outstanding balance
  # and the loan's annual rate (simple monthly accrual: balance * rate/100 / 12).
  # Clamped to the range [0, payment]. The outstanding balance defaults to the
  # most recent materialized balance before +as_of_date+; callers replaying a
  # payment history (see PaymentResplitter) can pass an explicit
  # +outstanding_balance+ so each period uses the balance left by the prior one.
  def interest_portion(payment_amount:, as_of_date:, outstanding_balance: nil)
    zero = Money.new(0, account.currency)
    return zero unless interest_rate.present? && interest_rate.to_d.positive?

    outstanding = outstanding_balance || outstanding_balance_before(as_of_date)
    return zero unless outstanding.positive?

    payment = payment_amount.to_d.abs
    monthly_rate = interest_rate.to_d / 100 / PAYMENT_PERIODS_PER_YEAR
    interest = (outstanding * monthly_rate).round(2).clamp(0, payment)

    Money.new(interest, account.currency)
  end

  # Principal portion of a single payment (payment minus interest).
  def principal_portion(payment_amount:, as_of_date:, outstanding_balance: nil)
    Money.new(payment_amount.to_d.abs, account.currency) -
      interest_portion(payment_amount: payment_amount, as_of_date: as_of_date, outstanding_balance: outstanding_balance)
  end

  # Outstanding principal balance immediately before +date+, taken from the most
  # recent materialized balance strictly before that date. Falls back to the
  # loan's original balance when no prior balance has been materialized yet
  # (e.g. the first payment).
  def outstanding_balance_before(date)
    prior = account.balances.where("date < ?", date).order(:date).last
    prior&.balance || original_balance.amount
  end

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
end
