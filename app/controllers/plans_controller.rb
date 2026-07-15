class PlansController < ApplicationController
  # The Plan hub fronts budgets + goals under one nav entry, and only
  # replaces the Budgets entry for preview users (see
  # ApplicationHelper#plan_nav_item). Without the flag, fall through to the
  # budgets flow so a shared /plan link still lands somewhere sensible.
  before_action :redirect_to_budgets_unless_preview

  def show
    @budget = Budget.find_or_bootstrap(Current.family, start_date: Date.current, user: Current.user)
    @top_budget_categories = top_budget_categories(@budget)

    @goals = Goal.active_prepared_for(Current.family)
    @goals_summary = goals_summary(@goals)
    @linkable_account_count = Current.user.accessible_accounts
                                     .where(accountable_type: Goal::FUNDABLE_ACCOUNT_TYPES)
                                     .visible
                                     .count

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.plan"), nil ] ]
  end

  private
    def redirect_to_budgets_unless_preview
      redirect_to budgets_path unless preview_features_enabled?
    end

    # Biggest parent categories by what's actually been spent this month,
    # falling back to allocation size early in the month before spending
    # lands. Categories with neither spend nor an allocation are noise here.
    def top_budget_categories(budget)
      return [] unless budget.initialized?

      budget.budget_categories
            .includes(:category)
            .reject(&:subcategory?)
            .reject { |bc| bc.actual_spending.to_d.zero? && bc.budgeted_spending.to_d.zero? }
            .sort_by { |bc| [ -bc.actual_spending.to_d, -bc.budgeted_spending.to_d ] }
            .first(4)
    end

    # Aggregates for the goals card. Money sums only make sense in a single
    # currency, so goals denominated differently from the family's primary
    # currency stay in the row list but out of the totals (same assumption
    # as GoalsController#kpi_payload).
    def goals_summary(goals)
      currency = Current.family.primary_currency_code
      summable = goals.select { |goal| goal.currency == currency }
      targeted = summable.select { |goal| goal.target_amount.to_d.positive? }

      {
        saved_money: Money.new(summable.sum { |goal| goal.current_balance.to_d }, currency),
        target_money: Money.new(targeted.sum { |goal| goal.target_amount.to_d }, currency),
        behind_count: goals.count { |goal| !goal.paused? && goal.status == :behind },
        pending_count: goals.sum { |goal| goal.open_pledges.size }
      }
    end
end
