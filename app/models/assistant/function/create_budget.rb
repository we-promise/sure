class Assistant::Function::CreateBudget < Assistant::Function
  class << self
    def name
      "create_budget"
    end

    def description
      <<~INSTRUCTIONS
        Creates an additional budget for the user's family, alongside the ones
        they already have (see list_budgets).

        Use when the user wants to budget a subset of their accounts separately
        (e.g. "personal" vs "joint" accounts) or to try out a test budget next
        to their live one.

        Before calling, confirm the name and — if the budget should only track
        certain accounts — which accounts, by paraphrasing back to the user.
        Only call once they've confirmed.

        Parameters:
        - `name` (required): budget name, e.g. "Joint" or "Test".
        - `accounts` (optional): account names (exact) or account ids to scope
          the budget to. Omit to track all of the family's accounts.

        After creating, target the new budget by passing its name or slug as
        the `budget` parameter of get_budget and update_budget.

        On a soft failure (e.g. an account name doesn't match), the response
        includes the available account list so you can re-ask.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[name],
      properties: {
        name: {
          type: "string",
          description: "Budget name, e.g. 'Personal', 'Joint', or 'Test'."
        },
        accounts: {
          type: "array",
          items: { type: "string" },
          description: "Optional account names (exact) or account ids to scope this budget to. Omit to track all of the family's accounts."
        }
      }
    )
  end

  def call(params = {})
    name = params["name"].to_s.strip
    return error("name_required", "Please provide a name for the budget.") if name.blank?

    refs = Array(params["accounts"]).map { |r| r.to_s.strip }.reject(&:blank?)
    resolution = resolve_accounts(refs)
    return resolution if resolution.is_a?(Hash) && resolution[:success] == false

    plan = nil
    BudgetPlan.transaction do
      plan = family.budget_plans.new(name: name)
      resolution.each { |account| plan.budget_plan_accounts.build(account: account) }
      plan.save!
    end

    {
      success: true,
      name: plan.name,
      slug: plan.slug,
      accounts: plan.scoped? ? plan.accounts.order(:name).pluck(:name) : "all_accounts",
      message: "Budget '#{plan.name}' created. Use budget: \"#{plan.slug}\" with get_budget or update_budget to work with it."
    }
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    # Resolves account references (uuid or exact name) through the family —
    # raw ids are never trusted. Returns an Array of accounts on success or
    # an error payload Hash on failure.
    def resolve_accounts(refs)
      return [] if refs.empty?

      accounts = []
      unknown = []
      ambiguous = []

      refs.each do |ref|
        if valid_uuid?(ref)
          account = family.accounts.visible.find_by(id: ref)
          account ? accounts << account : unknown << ref
        else
          matches = family.accounts.visible.where(name: ref).to_a
          case matches.size
          when 0 then unknown << ref
          when 1 then accounts << matches.first
          else ambiguous << ref
          end
        end
      end

      if unknown.any?
        return error(
          "unknown_accounts",
          "Some accounts didn't match the family's accounts.",
          unknown_accounts: unknown,
          available_accounts: family_account_names
        )
      end

      if ambiguous.any?
        return error(
          "ambiguous_accounts",
          "Multiple accounts share a name. Ask the user which one to use.",
          ambiguous_names: ambiguous,
          available_accounts: family_account_names
        )
      end

      accounts.uniq
    end

    def error(key, message, extra = {})
      { success: false, error: key, message: message }.merge(extra)
    end
end
