# Reads the family's current budget (if they've set one up) and produces
# either a warning — categories over or near their limit — or, once the month
# is at least half over, a quiet positive signal that everything is on track.
# Reuses BudgetCategory's own health checks rather than re-deriving pace math.
class Insight::Generators::BudgetInsightGenerator < Insight::Generator
  produces "budget_at_risk", "budget_on_track"

  NEAR_LIMIT_MIN_ELAPSED = 0.0 # near-limit/over warnings fire any time
  ON_TRACK_MIN_ELAPSED = 0.5   # positive signal only once the month is half over
  MAX_LISTED_CATEGORIES = 3

  def generate
    budget = current_budget
    return [] unless budget&.initialized?

    parent_categories = budget.budget_categories.reject(&:subcategory?)
    over = parent_categories.select(&:over_budget_with_budget?)
    near = parent_categories.select { |bc| bc.budgeted? && bc.near_limit? }

    if over.any? || near.any?
      [ at_risk_insight(budget, over, near) ]
    elsif on_track_eligible?(budget, parent_categories)
      [ on_track_insight(budget) ]
    else
      []
    end
  end

  private
    def current_budget
      family.budgets
        .includes(budget_categories: :category)
        .where("start_date <= ? AND end_date >= ?", Date.current, Date.current)
        .first
    end

    def at_risk_insight(budget, over, near)
      flagged = over + near
      category_names = flagged.first(MAX_LISTED_CATEGORIES).map { |bc| bc.category.name }

      build_insight(
        insight_type: "budget_at_risk",
        priority: over.any? ? "high" : "medium",
        title: I18n.t("insights.titles.budget_at_risk", count: flagged.size),
        template_key: over.any? ? "budget_at_risk.over" : "budget_at_risk.near",
        facts: {
          categories: category_names.to_sentence,
          count: flagged.size,
          budget_spent_pct: round(budget.percent_of_budget_spent, 0).to_i
        },
        # The percent bucket keeps the body fresh as overall usage moves (a
        # >=10-point swing rewrites it) without nightly one-point churn.
        metadata: {
          over_category_ids: over.map { |bc| bc.category.id }.sort,
          near_category_ids: near.map { |bc| bc.category.id }.sort,
          budget_spent_pct_bucket: (round(budget.percent_of_budget_spent, 0).to_i / 10) * 10
        },
        period: budget.period,
        dedup_key: "budget_at_risk:#{month_token(budget.start_date)}"
      )
    end

    def on_track_insight(budget)
      build_insight(
        insight_type: "budget_on_track",
        priority: "low",
        title: I18n.t("insights.titles.budget_on_track"),
        template_key: "budget_on_track",
        facts: {
          spent: money_fact(budget.actual_spending),
          budgeted: money_fact(budget.budgeted_spending),
          budget_spent_pct: round(budget.percent_of_budget_spent, 0).to_i
        },
        # Bucketed to damp nightly churn: a one-point move shouldn't count as
        # a material change that rewrites the body or reactivates a dismissal.
        metadata: {
          budget_spent_pct_bucket: (round(budget.percent_of_budget_spent, 0).to_i / 10) * 10
        },
        period: budget.period,
        dedup_key: "budget_on_track:#{month_token(budget.start_date)}"
      )
    end

    def on_track_eligible?(budget, parent_categories)
      return false unless parent_categories.any?(&:budgeted?)

      total_days = (budget.end_date - budget.start_date).to_i + 1
      elapsed_days = (Date.current - budget.start_date).to_i + 1

      elapsed_days.to_f / total_days >= ON_TRACK_MIN_ELAPSED
    end
end
