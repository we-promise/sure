class Assistant::Function::DeleteBudget < Assistant::Function
  class << self
    def name
      "delete_budget"
    end

    def description
      <<~INSTRUCTIONS
        Deletes one of the family's budgets (see list_budgets), including all
        of its monthly budget data. The primary budget cannot be deleted.

        This is destructive and cannot be undone — only call after the user has
        explicitly confirmed which budget to delete.

        Parameters:
        - `budget` (required): the budget's name or slug.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[budget],
      properties: {
        budget: {
          type: "string",
          description: "Name or slug of the budget to delete (see list_budgets)."
        }
      }
    )
  end

  def call(params = {})
    plan = find_budget_plan!(params["budget"])

    if plan.is_default?
      return error("cannot_delete_default", "The primary budget can't be deleted.")
    end

    months = plan.budgets.count
    plan.destroy!

    {
      success: true,
      deleted_budget: plan.name,
      months_deleted: months,
      message: "Budget '#{plan.name}' and #{months} month(s) of budget data deleted."
    }
  rescue Assistant::Error => e
    error("invalid_params", e.message)
  end

  private
    def error(key, message)
      { success: false, error: key, message: message }
    end
end
