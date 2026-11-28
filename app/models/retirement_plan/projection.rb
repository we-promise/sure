# The simple FIRE tier's arithmetic, and nothing else.
#
# Pure: every input is a number handed in. Nothing here reads the clock, the
# database or the current request.
class RetirementPlan::Projection
  # BigDecimal bounds, because `clamp` returns the bound itself when it applies
  # and an Integer bound would hand callers an Integer.
  ZERO = BigDecimal("0")
  ONE = BigDecimal("1")

  # Two spending figures, on purpose. `annual_living_costs` is what a retired
  # portfolio has to fund, so it drives the FI number. `annual_expenses` is
  # everything the user spends now, loan payments included, so it drives the
  # derived savings rate.
  attr_reader :annual_living_costs, :annual_expenses, :annual_income, :current_assets, :safe_withdrawal_rate, :savings_rate

  def initialize(annual_living_costs:, annual_expenses:, annual_income:, current_assets:, safe_withdrawal_rate:, savings_rate: nil)
    @annual_living_costs = annual_living_costs.to_d
    @annual_expenses = annual_expenses.to_d
    @annual_income = annual_income.to_d
    @current_assets = current_assets.to_d
    @safe_withdrawal_rate = safe_withdrawal_rate.to_d
    @savings_rate = savings_rate&.to_d
  end

  # The portfolio that would fund a year's spending at the withdrawal rate.
  # Nil, rather than zero, when there is no spending to measure: a zero FI
  # number would read as "already independent". Unrounded (40,000 / 0.035 does
  # not end at the cent); rounding is the view's job, so compare it with a
  # tolerance or after rounding, never with `==`.
  def fi_number
    return nil unless annual_living_costs.positive? && safe_withdrawal_rate.positive?

    annual_living_costs / safe_withdrawal_rate
  end

  # The true ratio, which passes 1 once the user is independent. The bar uses
  # `bar_progress`; the figure printed beside it uses this.
  def progress
    return nil if fi_number.nil?

    current_assets / fi_number
  end

  def bar_progress
    progress&.clamp(ZERO, ONE)
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
    return ZERO unless annual_income.positive?

    ((annual_income - annual_expenses) / annual_income).clamp(ZERO, ONE)
  end

  def annual_contribution
    return ZERO unless annual_income.positive?

    annual_income * effective_savings_rate
  end
end
