class Assistant::Function::UpdateBudget < Assistant::Function
  class << self
    def name
      "update_budget"
    end

    def description
      <<~INSTRUCTIONS
        Updates the user's monthly budget: total budgeted spending, expected income,
        and/or per-category budgeted amounts.

        Call get_budget first to see current amounts and exact category names.
        Amounts are plain non-negative numbers in the family's currency. Only the
        fields and categories you pass are changed. Setting a subcategory's amount
        keeps its parent's total in sync automatically. The "Uncategorized" bucket
        cannot be set directly — it is the unallocated remainder of total budgeted
        spending.

        Parameters:
        - `month` (optional): "YYYY-MM" or "MMM-YYYY". Defaults to the current month.
        - `budgeted_spending` (optional): total planned spending for the month.
        - `expected_income` (optional): expected income for the month.
        - `categories` (optional): array of { category: <name or id>, amount: <number> }.

        At least one of budgeted_spending, expected_income, or categories is required.

        Example (set the total and two category allocations for August 2026):

        ```
        update_budget({
          month: "2026-08",
          budgeted_spending: 6500,
          categories: [
            { category: "Groceries", amount: 900 },
            { category: "Dining Out", amount: 250 }
          ]
        })
        ```
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      properties: {
        month: {
          type: "string",
          description: "Target month in YYYY-MM or MMM-YYYY format. Defaults to the current month."
        },
        budgeted_spending: {
          type: "number",
          minimum: 0,
          description: "Total planned spending for the month, in the family currency."
        },
        expected_income: {
          type: "number",
          minimum: 0,
          description: "Expected income for the month, in the family currency."
        },
        categories: {
          type: "array",
          description: "Per-category budget allocations to set.",
          items: {
            type: "object",
            properties: {
              category: {
                type: "string",
                description: "Category name (exact match, case-insensitive) or category id (use get_categories)."
              },
              amount: {
                type: "number",
                minimum: 0,
                description: "New budgeted amount for this category."
              }
            },
            required: [ "category", "amount" ],
            additionalProperties: false
          }
        }
      }
    )
  end

  def call(params = {})
    category_changes = Array(params["categories"])
    unless params.key?("budgeted_spending") || params.key?("expected_income") || category_changes.any?
      return error("no_changes", "Provide at least one of budgeted_spending, expected_income, or categories.")
    end

    budget = find_budget(params["month"])
    return error("invalid_month", "No budget exists (or can be created) for that month — it is outside the valid budget range.") unless budget

    attrs = {}
    attrs[:budgeted_spending] = parse_amount!(params["budgeted_spending"], "budgeted_spending") if params.key?("budgeted_spending")
    attrs[:expected_income] = parse_amount!(params["expected_income"], "expected_income") if params.key?("expected_income")

    updated = []
    Budget.transaction do
      budget.update!(attrs) if attrs.any?

      category_changes.each do |change|
        budget_category = find_budget_category!(budget, change.is_a?(Hash) ? change["category"] : nil)
        amount = parse_amount!(change["amount"], "amount for '#{budget_category.name}'")
        budget_category.update_budgeted_spending!(amount)
        updated << { category: budget_category.name, budgeted_spending: format_money(budget_category.reload.budgeted_spending) }
      end
    end

    budget.reload
    {
      success: true,
      month: budget.to_param,
      totals: {
        budgeted_spending: format_money(budget.budgeted_spending),
        expected_income: format_money(budget.expected_income),
        allocated_spending: format_money(budget.allocated_spending),
        available_to_allocate: format_money(budget.available_to_allocate)
      },
      updated_categories: updated,
      message: "Budget for #{budget.start_date.strftime('%B %Y')} updated."
    }
  rescue Assistant::Error => e
    error("invalid_params", e.message)
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def find_budget(raw_month)
      base = raw_month.present? ? parse_month!(raw_month) : nil

      # Mirrors GetBudget#resolve_month_start so month slugs round-trip between
      # the two tools even when the family uses a custom month start day.
      start_date = if family.uses_custom_month_start?
        base ? Date.new(base.year, base.month, family.month_start_day) : family.custom_month_start_for(Date.current)
      else
        (base || Date.current).beginning_of_month
      end

      Budget.find_or_bootstrap(family, start_date: start_date, user: user)
    end

    def parse_month!(raw)
      fmt = case raw
      when /\A\d{4}-\d{2}\z/         then "%Y-%m"
      when /\A[A-Za-z]{3}-\d{4}\z/   then "%b-%Y"
      end
      raise Assistant::Error, "Invalid month: #{raw}. Use YYYY-MM or MMM-YYYY." if fmt.nil?

      Date.strptime(raw, fmt)
    rescue ArgumentError
      raise Assistant::Error, "Invalid month: #{raw}. Use YYYY-MM or MMM-YYYY."
    end

    def parse_amount!(raw, label)
      value = Float(raw)
      raise Assistant::Error, "#{label} must be a non-negative number." if value.negative?
      value
    rescue ArgumentError, TypeError
      raise Assistant::Error, "#{label} must be a non-negative number."
    end

    def find_budget_category!(budget, ref)
      ref = ref.to_s.strip
      raise Assistant::Error, "Each categories entry needs a category name or id." if ref.blank?

      category = valid_uuid?(ref) ? family.categories.find_by(id: ref) : nil
      category ||= family.categories.where("LOWER(name) = ?", ref.downcase).first
      raise Assistant::Error, "Category '#{ref}' not found. Use get_categories to list categories." unless category

      budget.budget_categories.find_by(category_id: category.id) ||
        raise(Assistant::Error, "No budget row exists for category '#{category.name}' in #{budget.to_param}.")
    end

    def format_money(value)
      Money.new(value || 0, family.currency).format
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
