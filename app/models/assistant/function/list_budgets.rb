class Assistant::Function::ListBudgets < Assistant::Function
  class << self
    def name
      "list_budgets"
    end

    def description
      <<~INSTRUCTIONS
        Lists the family's budgets. Most families have just one (the primary
        budget), but a family can keep several side by side — e.g. a "Personal"
        budget scoped to some accounts and a "Joint" one scoped to others, or a
        test budget observed next to the live one.

        Use the returned name or slug as the `budget` parameter of get_budget
        and update_budget to read or edit a specific budget. A budget with
        accounts "all_accounts" tracks every account in the family; otherwise
        it only counts transactions from the listed accounts.
      INSTRUCTIONS
    end
  end

  def call(params = {})
    {
      budgets: family.budget_plans.default_first.map do |plan|
        {
          name: plan.name,
          slug: plan.slug,
          is_default: plan.is_default,
          accounts: plan.scoped_account_names(user: user),
          initialized_months: plan.budgets.where.not(budgeted_spending: nil).count
        }
      end
    }
  end
end
