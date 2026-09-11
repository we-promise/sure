class Assistant::Function::UpdateBudget < Assistant::Function
  include Assistant::Function::MonthResolvable

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

    start_date = resolve_month_start(params["month"])
    unless Budget.budget_date_valid?(start_date, family: family)
      return error("invalid_month", "No budget exists (or can be created) for that month — it is outside the valid budget range.")
    end

    attrs = {}
    attrs[:budgeted_spending] = parse_amount!(params["budgeted_spending"], "budgeted_spending") if params.key?("budgeted_spending")
    attrs[:expected_income] = parse_amount!(params["expected_income"], "expected_income") if params.key?("expected_income")

    budget = nil
    updated = []
    # Bootstrap and all writes share one transaction so a bad entry can't
    # leave a newly created (or half-updated) budget behind.
    Budget.transaction do
      budget = Budget.find_or_bootstrap(family, start_date: start_date, user: user)

      budget.update!(attrs) if attrs.any?

      changes = category_changes.map do |change|
        budget_category = find_budget_category!(budget, change.is_a?(Hash) ? change["category"] : nil)
        [ budget_category, parse_amount!(change["amount"], "amount for '#{budget_category.name}'") ]
      end

      # Subcategory updates sync their parent's total, so explicit parent
      # amounts apply last to keep results independent of the array order.
      subcategories, parents = changes.partition { |budget_category, _amount| budget_category.subcategory? }
      (subcategories + parents).each do |budget_category, amount|
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
    def parse_amount!(raw, label)
      value = Float(raw)
      raise Assistant::Error, "#{label} must be a non-negative number." if !value.finite? || value.negative?
      value
    rescue ArgumentError, TypeError
      raise Assistant::Error, "#{label} must be a non-negative number."
    end

    def find_budget_category!(budget, ref)
      ref = ref.to_s.strip
      raise Assistant::Error, "Each categories entry needs a category name or id." if ref.blank?

      category = valid_uuid?(ref) ? family.categories.find_by(id: ref) : nil
      category ||= family.categories.where("LOWER(name) = ?", ref.downcase).first

      if category.nil?
        if Category.all_uncategorized_names.any? { |name| name.casecmp?(ref) }
          raise Assistant::Error, "'#{ref}' is the unallocated remainder of budgeted_spending and cannot be set directly. Adjust budgeted_spending or category amounts instead."
        end
        raise Assistant::Error, "Category '#{ref}' not found. Use get_categories to list categories."
      end

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
