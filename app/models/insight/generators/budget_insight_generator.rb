# Compares actual spending pace to the monthly budget and surfaces an insight
# when spending is significantly ahead of or behind the expected pace.
class Insight::Generators::BudgetInsightGenerator < Insight::Generator
  OVER_PACE_THRESHOLD  =  0.15  # 15% ahead of pace → at_risk
  UNDER_PACE_THRESHOLD = -0.10  # 10% under pace → no insight (healthy)

  def generate
    current_period = Period.current_month_for(family)

    budget = family.budgets.find_by(start_date: current_period.start_date)
    return [] if budget.nil?
    return [] unless budget.initialized?

    budgeted = budget.budgeted_spending.to_f
    actual   = budget.actual_spending.to_f
    return [] if budgeted.zero?

    elapsed    = [ (Date.current - current_period.start_date).to_i + 1, 1 ].max
    total_days = [ (current_period.end_date - current_period.start_date).to_i + 1, 1 ].max
    pace       = elapsed.to_f / total_days

    paced_expected = budgeted * pace
    return [] if paced_expected.zero?

    overage_ratio = (actual - paced_expected) / paced_expected

    return [] if overage_ratio < OVER_PACE_THRESHOLD && overage_ratio > UNDER_PACE_THRESHOLD

    at_risk      = overage_ratio >= OVER_PACE_THRESHOLD
    insight_type = at_risk ? "budget_at_risk" : "budget_on_track"
    pct          = (overage_ratio * 100).round(0)

    metadata = {
      "actual_spending"     => actual.round(2),
      "budgeted_spending"   => budgeted.round(2),
      "paced_expected"      => paced_expected.round(2),
      "overage_percent"     => pct,
      "days_elapsed"        => elapsed,
      "days_total"          => total_days
    }

    body = if at_risk
      generate_body(
        "With #{elapsed} of #{total_days} days elapsed, you've spent #{currency_symbol}#{actual.round(2)} " \
        "against a #{currency_symbol}#{budgeted.round(2)} budget — #{pct.abs}% ahead of the expected pace."
      )
    else
      remaining = total_days - elapsed
      generate_body(
        "Your spending of #{currency_symbol}#{actual.round(2)} is on track with your " \
        "#{currency_symbol}#{budgeted.round(2)} budget, with #{remaining} days left in the month."
      )
    end

    [
      GeneratedInsight.new(
        insight_type: insight_type,
        priority:     at_risk ? "high" : "low",
        title:        I18n.t("insights.#{insight_type}.title"),
        body:         body,
        metadata:     metadata,
        currency:     family.currency,
        period_start: current_period.start_date,
        period_end:   current_period.end_date,
        dedup_key:    "#{insight_type}:#{current_period.start_date.strftime("%Y-%m")}"
      )
    ]
  end
end
