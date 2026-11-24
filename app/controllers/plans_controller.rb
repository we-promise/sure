class PlansController < ApplicationController
  include BudgetOwnership

  # The Plan hub fronts budgets + goals under one nav entry, and only
  # replaces the Budgets entry for preview users (see
  # ApplicationHelper#plan_nav_item). Without the flag, fall through to the
  # budgets flow so a shared /plan link still lands somewhere sensible.
  before_action :redirect_to_budgets_unless_preview

  def show
    # Captured once: the retirement card's projection takes it, and the
    # budget below resolves the same day.
    @as_of = Date.current
    @budget = resolve_budget(@as_of)
    @editable = @budget.editable_by?(Current.user)
    @switch_options = budget_switch_options(@budget)
    @top_budget_categories = @budget.initialized? ? @budget.top_spending_categories : []

    @goals = Goal.active_prepared_for(Current.family)
    @goals_summary = Goal.summary_for(@goals, currency: Current.family.primary_currency_code)
    # Includes completed/archived goals: the hub is the only route to the
    # goals index for preview users, so the "All goals" link must survive
    # an empty *active* list.
    @family_has_goals = @goals.any? || Current.family.goals.exists?
    @linkable_account_count = Current.user.accessible_accounts
                                     .where(accountable_type: Goal::FUNDABLE_ACCOUNT_TYPES)
                                     .visible
                                     .count

    @retirement_plan = RetirementPlan.for(Current.user)
    @retirement_projection = @retirement_plan.projection(as_of: @as_of)

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.plan"), nil ] ]
  end

  private
    def redirect_to_budgets_unless_preview
      redirect_to budgets_path unless preview_features_enabled?
    end
end
