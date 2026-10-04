# The borrower's insurance premium, period by period.
#
# Charged ALONGSIDE the instalment, never inside it. The amortisation repays
# principal and interest and nothing else -- that is what makes its rows agree
# with a lender's own table -- so a premium folded into `Payment#payment` would
# make every figure derived from the schedule disagree with the loan. This
# reads the schedule and returns a parallel series instead.
#
# Two policies, which is what lenders sell:
#
#   level_term       the premium is charged on the ORIGINAL principal for the
#                    life of the loan, so it does not fall as the loan is
#                    repaid. The same amount every month.
#   decreasing_life  the premium is charged on what is still outstanding, so it
#                    falls with the balance. This is the default reading when a
#                    rate is recorded without a type, because a premium that
#                    tracks the debt is the conservative assumption: it never
#                    overstates the total cost of a policy the borrower has not
#                    described.
#
# The rate is annual and in percent, like `interest_rate`, and is charged
# monthly at a twelfth of it. The base for a decreasing policy is the balance
# OUTSTANDING AT THE START of the period -- the balance the borrower carried
# through the month the premium covers, not the one they are left with after
# paying it.
class Loan::Insurance
  Premium = Data.define(:number, :date, :amount)

  LEVEL_TERM = "level_term".freeze
  DECREASING_LIFE = "decreasing_life".freeze
  RATE_TYPES = [ LEVEL_TERM, DECREASING_LIFE ].freeze

  MONTHS_PER_YEAR = 12

  attr_reader :schedule, :annual_rate, :rate_type, :principal, :currency

  class << self
    # Nil when the loan carries no premium to charge, or nothing to charge it
    # against. Callers read `Loan#total_insurance`, which turns that nil into a
    # zero of the right currency.
    def for(loan)
      return nil unless loan.insurance_rate&.positive?

      schedule = loan.amortization_schedule
      return nil if schedule.nil?

      new(
        schedule: schedule,
        annual_rate: loan.insurance_rate,
        rate_type: loan.insurance_rate_type,
        principal: loan.original_balance,
        currency: loan.account.currency
      )
    end
  end

  def initialize(schedule:, annual_rate:, rate_type:, principal:, currency:)
    @schedule = schedule
    @annual_rate = BigDecimal(annual_rate.to_s)
    @rate_type = rate_type
    @principal = principal
    @currency = currency
  end

  # One premium per scheduled payment, oldest first.
  def premiums
    @premiums ||= begin
      opening = principal.amount

      schedule.payments.map do |payment|
        base = level_term? ? principal.amount : opening
        opening = payment.ending_balance.amount

        Premium.new(
          number: payment.number,
          date: payment.date,
          amount: money((base * monthly_rate).round(currency_precision))
        )
      end
    end
  end

  # What the policy costs over the life of the loan.
  def total
    money(premiums.sum(BigDecimal("0")) { |premium| premium.amount.amount })
  end

  # The premium charged against a given scheduled payment number, or nil when
  # the schedule holds no such payment.
  def premium_for(number)
    premiums.find { |premium| premium.number == number }
  end

  def level_term?
    rate_type == LEVEL_TERM
  end

  private
    def monthly_rate
      @monthly_rate ||= annual_rate / (100 * MONTHS_PER_YEAR)
    end

    def currency_precision
      @currency_precision ||= Money::Currency.new(currency).default_precision || 2
    end

    def money(value)
      Money.new(value, currency)
    end
end
