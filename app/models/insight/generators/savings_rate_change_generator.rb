# Surfaces an insight when the savings rate changes significantly vs the prior month.
# Savings rate = (income - expenses) / income.
class Insight::Generators::SavingsRateChangeGenerator < Insight::Generator
  CHANGE_THRESHOLD = 0.05  # 5 percentage-point swing required to surface an insight

  def generate
    income_stmt = family.income_statement

    current_period = Period.current_month_for(family)
    prior_period   = Period.last_month_for(family)

    current_income  = income_stmt.income_totals(period: current_period).total.to_f
    current_expense = income_stmt.expense_totals(period: current_period).total.to_f
    prior_income    = income_stmt.income_totals(period: prior_period).total.to_f
    prior_expense   = income_stmt.expense_totals(period: prior_period).total.to_f

    return [] if current_income.zero? || prior_income.zero?

    current_rate = (current_income - current_expense) / current_income
    prior_rate   = (prior_income   - prior_expense)   / prior_income

    change = current_rate - prior_rate
    return [] if change.abs < CHANGE_THRESHOLD

    direction = change > 0 ? "improved" : "declined"

    metadata = {
      "current_savings_rate" => (current_rate * 100).round(1),
      "prior_savings_rate"   => (prior_rate * 100).round(1),
      "change_points"        => (change * 100).round(1),
      "direction"            => direction
    }

    body = generate_body(
      "Your savings rate #{direction} from #{(prior_rate * 100).round(1)}% last month " \
      "to #{(current_rate * 100).round(1)}% this month."
    )

    [
      GeneratedInsight.new(
        insight_type: "savings_rate_change",
        priority:     change.abs >= 0.10 ? "high" : "medium",
        title:        I18n.t("insights.savings_rate_change.title", direction: direction),
        body:         body,
        metadata:     metadata,
        currency:     family.currency,
        period_start: current_period.start_date,
        period_end:   current_period.end_date,
        dedup_key:    "savings_rate_change:#{Date.current.strftime("%Y-%m")}"
      )
    ]
  end
end
