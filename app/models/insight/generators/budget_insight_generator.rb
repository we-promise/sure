class Insight::Generators::BudgetInsightGenerator < Insight::Generator
  AT_RISK_MARGIN = 0.15
  ON_TRACK_MARGIN = 0.05

  def generate
    budget = current_budget
    return [] unless budget&.initialized?

    budgeted = budget.budgeted_spending.to_f
    return [] if budgeted <= 0

    actual = budget.actual_spending.to_f
    spend_fraction = actual / budgeted
    time_fraction = elapsed_fraction(budget)
    return [] if time_fraction <= 0

    month_key = budget.start_date.strftime("%Y-%m")

    if spend_fraction > time_fraction + AT_RISK_MARGIN
      build_at_risk(budget, budgeted, actual, spend_fraction, time_fraction, month_key)
    elsif spend_fraction <= time_fraction + ON_TRACK_MARGIN
      build_on_track(budget, budgeted, actual, spend_fraction, time_fraction, month_key)
    else
      []
    end
  end

  private
    def build_at_risk(budget, budgeted, actual, spend_fraction, time_fraction, month_key)
      ahead_pp = ((spend_fraction - time_fraction) * 100).round

      metadata = {
        "budgeted" => budgeted.round(2),
        "actual" => actual.round(2),
        "percent_spent" => (spend_fraction * 100).round,
        "percent_of_period_elapsed" => (time_fraction * 100).round
      }

      fallback = "You've spent #{format_money(actual)} of your #{format_money(budgeted)} budget this month — " \
                 "about #{ahead_pp} points ahead of where you'd expect to be by now."

      body = generate_body(
        facts: {
          signal: "budget_at_risk",
          budgeted: format_money(budgeted),
          spent_so_far: format_money(actual),
          percent_spent: (spend_fraction * 100).round,
          percent_of_month_elapsed: (time_fraction * 100).round
        },
        fallback: fallback
      )

      [
        GeneratedInsight.new(
          insight_type: "budget_at_risk",
          priority: "high",
          title: "Spending is ahead of budget",
          body: body,
          metadata: metadata,
          currency: currency,
          period_start: budget.start_date,
          period_end: budget.end_date,
          dedup_key: "budget_at_risk:#{month_key}"
        )
      ]
    end

    def build_on_track(budget, budgeted, actual, spend_fraction, time_fraction, month_key)
      metadata = {
        "budgeted" => budgeted.round(2),
        "actual" => actual.round(2),
        "percent_spent" => (spend_fraction * 100).round,
        "percent_of_period_elapsed" => (time_fraction * 100).round
      }

      fallback = "You're on track this month — #{format_money(actual)} spent of your #{format_money(budgeted)} budget, " \
                 "right in line with the month so far."

      body = generate_body(
        facts: {
          signal: "budget_on_track",
          budgeted: format_money(budgeted),
          spent_so_far: format_money(actual),
          percent_spent: (spend_fraction * 100).round,
          percent_of_month_elapsed: (time_fraction * 100).round
        },
        fallback: fallback
      )

      [
        GeneratedInsight.new(
          insight_type: "budget_on_track",
          priority: "low",
          title: "Budget is on track",
          body: body,
          metadata: metadata,
          currency: currency,
          period_start: budget.start_date,
          period_end: budget.end_date,
          dedup_key: "budget_on_track:#{month_key}"
        )
      ]
    end

    def current_budget
      if family.uses_custom_month_start?
        period = family.current_custom_month_period
        family.budgets.find_by(start_date: period.start_date, end_date: period.end_date)
      else
        family.budgets.find_by(
          start_date: Date.current.beginning_of_month,
          end_date: Date.current.end_of_month
        )
      end
    end

    def elapsed_fraction(budget)
      total_days = (budget.end_date - budget.start_date).to_i + 1
      elapsed_days = (Date.current - budget.start_date).to_i + 1
      return 0.0 if total_days <= 0

      [ [ elapsed_days.to_f / total_days, 0.0 ].max, 1.0 ].min
    end
end
