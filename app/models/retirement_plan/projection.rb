# The simple FIRE tier's arithmetic, and nothing else.
#
# Pure: every input is a number handed in, and the reference date is one of
# them. Nothing here reads the clock, the database or the current request, so a
# page that shows several of these figures captures one `as_of` and they all
# agree.
#
# Compounding is annual, with the year's contribution added at the end of the
# year:
#
#   V(n + 1) = V(n) * (1 + r) + C
#
# Named here because "matches a hand-computed table to the cent" only means
# something once the recurrence is fixed.
class RetirementPlan::Projection
  # How far the chart runs when the user has not set a retirement date.
  DEFAULT_HORIZON_YEARS = 30

  attr_reader :as_of, :annual_expenses, :annual_income, :current_assets,
              :safe_withdrawal_rate, :expected_annual_return, :savings_rate, :retirement_date

  def initialize(as_of:, annual_expenses:, annual_income:, current_assets:, safe_withdrawal_rate:, expected_annual_return:, savings_rate: nil, retirement_date: nil)
    @as_of = as_of.to_date
    @annual_expenses = annual_expenses.to_d
    @annual_income = annual_income.to_d
    @current_assets = current_assets.to_d
    @safe_withdrawal_rate = safe_withdrawal_rate.to_d
    @expected_annual_return = expected_annual_return.to_d
    @savings_rate = savings_rate&.to_d
    @retirement_date = retirement_date&.to_date
  end

  # The portfolio that would fund a year's spending at the withdrawal rate.
  # Nil, rather than zero, when there is no spending to measure: a zero FI
  # number would read as "already independent".
  def fi_number
    return nil unless annual_expenses.positive? && safe_withdrawal_rate.positive?

    annual_expenses / safe_withdrawal_rate
  end

  # The true ratio, which passes 1 once the user is independent. The bar uses
  # `bar_progress`; the figure printed beside it uses this.
  def progress
    return nil if fi_number.nil?

    current_assets / fi_number
  end

  def bar_progress
    progress&.clamp(0, 1)
  end

  def financially_independent?
    progress.present? && progress >= 1
  end

  # The user's saved rate, or one derived from income and expenses. Clamped at
  # zero: spending more than you earn is not a negative contribution to the
  # portfolio, and projecting one would shrink it for a reason the plan does
  # not model.
  def effective_savings_rate
    return savings_rate if savings_rate
    return 0 unless annual_income.positive?

    ((annual_income - annual_expenses) / annual_income).clamp(0, 1)
  end

  def annual_contribution
    return 0 unless annual_income.positive?

    annual_income * effective_savings_rate
  end

  # Whole years only: a retirement date eleven months away is zero years of
  # compounding, not one. A date already passed projects nothing forward.
  def years_to_retirement
    return nil if retirement_date.nil?
    return 0 if retirement_date <= as_of

    years = retirement_date.year - as_of.year
    years -= 1 if as_of.advance(years: years) > retirement_date
    years
  end

  # One point per year, starting with today's assets at `as_of`.
  def yearly_series
    value = current_assets

    (0..horizon_years).map do |year|
      value = value * (1 + expected_annual_return) + annual_contribution unless year.zero?
      { date: as_of.advance(years: year), value: value }
    end
  end

  def projected_total
    return nil if retirement_date.nil?

    yearly_series.last[:value]
  end

  private
    def horizon_years
      years_to_retirement || DEFAULT_HORIZON_YEARS
    end
end
