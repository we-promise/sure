# Resolves "whose budget is this request about" from the `owner` query
# param, shared by BudgetsController, BudgetCategoriesController, and
# PlansController now that a household budget and personal budgets can
# coexist. `owner` is either "household", a user id, or absent (defaults to
# the signed-in user's own budget).
module BudgetOwnership
  extend ActiveSupport::Concern

  # budget_owner_query lives in BudgetsHelper (not defined here) so it's
  # usable both from controller redirects (via this include) and from any
  # view context, including isolated partial/view tests.
  included do
    include BudgetsHelper
  end

  private
    def viewing_household_budget?
      params[:owner] == "household"
    end

    # Falls back to Current.user whenever the requested owner can't be
    # resolved or isn't shared with the signed-in user, rather than raising
    # — worst case the request just shows the viewer their own budget.
    def budget_target_user
      return Current.user if params[:owner].blank? || viewing_household_budget?

      candidate = Current.family.users.find_by(id: params[:owner])
      return Current.user if candidate.nil? || candidate.id == Current.user.id
      return candidate if BudgetShare.exists?(owner_id: candidate.id, viewer_id: Current.user.id)

      Current.user
    end

    def resolve_budget(start_date)
      target_user = budget_target_user

      if target_user != Current.user
        # Viewing another family member's shared budget: resolve an existing
        # budget for that period without creating one on their behalf — a
        # mere page view shouldn't vivify a row in someone else's budget
        # history. Falls back to the viewer's own budget (auto-created) when
        # the owner hasn't set one up yet, same as the household fallback
        # below, so shared-budget navigation doesn't dead-end.
        budget_start, budget_end = Budget.period_for(start_date, family: Current.family)
        existing = Current.family.budgets.find_by(start_date: budget_start, end_date: budget_end, user: target_user)
        return existing if existing

        return Budget.find_or_bootstrap(Current.family, start_date: start_date, user: Current.user, household: false)
      end

      budget = Budget.find_or_bootstrap(
        Current.family,
        start_date: start_date,
        user: target_user,
        household: viewing_household_budget?
      )

      return budget if budget || !viewing_household_budget?

      # Household budget was explicitly requested but the family disabled it
      # (stale link, bookmarked URL) — fall back to the viewer's own budget
      # rather than a hard 404.
      Budget.find_or_bootstrap(Current.family, start_date: start_date, user: Current.user, household: false)
    end

    def ensure_budget_editable!
      raise ActiveRecord::RecordNotFound unless @budget.editable_by?(Current.user)
    end

    # Pills for the household/personal budget switcher. Empty (no switcher)
    # unless personal_budgets is on — families that never turned it on keep
    # the single, switcher-less budget page they've always had. Household
    # gets a people icon; every person (the viewer included) gets a
    # colored initial avatar, so all three read as "who" at a glance.
    def budget_switch_options(budget)
      return [] unless Current.family.personal_budgets?

      options = []

      if Current.family.household_budget_enabled?
        options << {
          label: t("budgets.switcher.household"),
          icon: "users",
          owner_param: "household",
          active: budget.user_id.nil?
        }
      end

      options << {
        label: Current.user.display_name,
        icon: nil,
        owner_param: Current.user.id,
        active: budget.user_id == Current.user.id
      }

      Current.user.budget_owners_shared_with_me.find_each do |owner|
        options << {
          label: owner.display_name,
          icon: nil,
          owner_param: owner.id,
          active: budget.user_id == owner.id
        }
      end

      options
    end
end
