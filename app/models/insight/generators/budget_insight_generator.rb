# Reads the family's current budgets (if they've set any up) and produces,
# per budget, either a warning — categories over or near their limit — or,
# once the month is at least half over, a quiet positive signal that
# everything is on track. Reuses BudgetCategory's own health checks rather
# than re-deriving pace math.
class Insight::Generators::BudgetInsightGenerator < Insight::Generator
  produces "budget_at_risk", "budget_on_track"

  NEAR_LIMIT_MIN_ELAPSED = 0.0 # near-limit/over warnings fire any time
  ON_TRACK_MIN_ELAPSED = 0.5   # positive signal only once the month is half over
  MAX_LISTED_CATEGORIES = 3

  def generate
    current_budgets.flat_map do |budget|
      next [] unless budget.initialized?

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
  end

  private
    def current_budgets
      family.budgets
        .includes(:budget_plan, budget_categories: :category)
        .where("start_date <= ? AND end_date >= ?", Date.current, Date.current)
        .order(:created_at)
    end

    def at_risk_insight(budget, over, near)
      flagged = over + near
      category_names = flagged.first(MAX_LISTED_CATEGORIES).map { |bc| bc.category.name }

      build_insight(
        insight_type: "budget_at_risk",
        priority: over.any? ? "high" : "medium",
        title: insight_title("budget_at_risk", budget, count: flagged.size),
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
          budget_spent_pct_bucket: (round(budget.percent_of_budget_spent, 0).to_i / 10) * 10,
          budget_param: budget.to_param
        },
        period: budget.period,
        dedup_key: "budget_at_risk:#{dedup_scope(budget)}#{month_token(budget.start_date)}"
      )
    end

    def on_track_insight(budget)
      build_insight(
        insight_type: "budget_on_track",
        priority: "low",
        title: insight_title("budget_on_track", budget),
        template_key: "budget_on_track",
        facts: {
          spent: format_money(budget.actual_spending),
          budgeted: format_money(budget.budgeted_spending),
          budget_spent_pct: round(budget.percent_of_budget_spent, 0).to_i
        },
        # Bucketed to damp nightly churn: a one-point move shouldn't count as
        # a material change that rewrites the body or reactivates a dismissal.
        metadata: {
          budget_spent_pct_bucket: (round(budget.percent_of_budget_spent, 0).to_i / 10) * 10,
          budget_param: budget.to_param
        },
        period: budget.period,
        dedup_key: "budget_on_track:#{dedup_scope(budget)}#{month_token(budget.start_date)}"
      )
    end

    # The default plan keeps the legacy month-only key so existing insights
    # don't duplicate after upgrade; sibling budgets get their plan id.
    def dedup_scope(budget)
      budget.budget_plan.is_default? ? "" : "#{budget.budget_plan_id}:"
    end

    def insight_title(insight_type, budget, count: nil)
      if budget.budget_plan.is_default?
        I18n.t("insights.titles.#{insight_type}", count: count)
      else
        I18n.t("insights.titles.#{insight_type}_named", budget: budget.budget_plan.name, count: count)
      end
    end

    def on_track_eligible?(budget, parent_categories)
      return false unless parent_categories.any?(&:budgeted?)

      total_days = (budget.end_date - budget.start_date).to_i + 1
      elapsed_days = (Date.current - budget.start_date).to_i + 1

      elapsed_days.to_f / total_days >= ON_TRACK_MIN_ELAPSED
    end
end
