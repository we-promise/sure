class Insight::Generators::SavingsRateChangeGenerator < Insight::Generator
  CHANGE_THRESHOLD_PP = 5.0
  HIGH_PRIORITY_PP = 10.0

  def generate
    return [] if family.accounts.visible.none?

    recent_month = Date.current.beginning_of_month - 1.month
    prior_month = Date.current.beginning_of_month - 2.months

    recent_rate = savings_rate_for(recent_month)
    prior_rate = savings_rate_for(prior_month)

    return [] if recent_rate.nil? || prior_rate.nil?

    change_pp = (recent_rate - prior_rate).round(1)
    return [] if change_pp.abs < CHANGE_THRESHOLD_PP

    direction = change_pp.positive? ? "improved" : "declined"
    priority = change_pp.abs >= HIGH_PRIORITY_PP ? "high" : "medium"

    metadata = {
      "recent_savings_rate" => recent_rate.round(1),
      "prior_savings_rate" => prior_rate.round(1),
      "change_pp" => change_pp,
      "direction" => direction
    }

    fallback = "Your savings rate #{direction} from #{prior_rate.round}% to #{recent_rate.round}% " \
               "(a #{change_pp.abs.round}-point change) last month."

    body = generate_body(
      facts: {
        signal: "savings_rate_change",
        previous_rate_percent: prior_rate.round(1),
        current_rate_percent: recent_rate.round(1),
        change_in_points: change_pp.abs.round(1),
        direction: direction
      },
      fallback: fallback
    )

    [
      GeneratedInsight.new(
        insight_type: "savings_rate_change",
        priority: priority,
        title: "Savings rate #{direction}",
        body: body,
        metadata: metadata,
        currency: currency,
        period_start: recent_month.beginning_of_month,
        period_end: recent_month.end_of_month,
        dedup_key: "savings_rate_change:#{recent_month.strftime('%Y-%m')}"
      )
    ]
  end

  private
    def savings_rate_for(month)
      period = Period.custom(start_date: month.beginning_of_month, end_date: month.end_of_month)
      statement = family.income_statement

      income = statement.income_totals(period: period).total.to_f
      expense = statement.expense_totals(period: period).total.to_f

      return nil if income <= 0

      ((income - expense) / income) * 100.0
    end
end
