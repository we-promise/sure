class Assistant::Function::GetBudget < Assistant::Function
  include ActiveSupport::NumberHelper

  MAX_PRIOR_MONTHS = 11

  class << self
    def name
      "get_budget"
    end

    def description
      <<~INSTRUCTIONS
        Use this to see how the user is tracking against their monthly budget — total
        budgeted vs spent and a parent/subcategory breakdown matching the budget UI.

        This is great for answering questions like:
        - How am I tracking against my budget this month?
        - Which categories am I over budget on?
        - How does this month's spending compare to the last few months?

        Parameters:
        - `month` (optional): "YYYY-MM" or "MMM-YYYY". Defaults to the current month.
        - `prior_months` (optional): integer 0..#{MAX_PRIOR_MONTHS}. Number of months
          preceding the target month to include for trend comparison. Default 0.

        Example (current month only):

        ```
        get_budget({})
        ```

        Example (current month plus last 2 months):

        ```
        get_budget({ month: "#{Date.current.strftime('%Y-%m')}", prior_months: 2 })
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
        prior_months: {
          type: "integer",
          description: "Number of months before the target month to also return for trend comparison.",
          minimum: 0,
          maximum: MAX_PRIOR_MONTHS
        }
      }
    )
  end

  def call(params = {})
    target_start = resolve_month_start(params["month"])
    prior = [ params["prior_months"].to_i, 0 ].max
    prior = [ prior, MAX_PRIOR_MONTHS ].min

    month_starts = (0..prior).map { |offset| shift_months(target_start, -offset) }.reverse
    requested = month_starts.count { |start_date| Budget.budget_date_valid?(start_date, family: family) }

    months = month_starts.filter_map do |start_date|
      next unless Budget.budget_date_valid?(start_date, family: family)
      build_month_payload(start_date, bootstrap: start_date == target_start)
    end

    result = {
      currency: family.currency,
      months: months
    }
    unavailable = requested - months.length
    result[:months_unavailable] = unavailable if unavailable > 0
    result
  end

  private
    def build_month_payload(start_date, bootstrap:)
      budget = if bootstrap
        Budget.find_or_bootstrap(family, start_date: start_date, user: user)
      else
        budget_start, budget_end = Budget.period_for(start_date, family: family)
        family.budgets.find_by(start_date: budget_start, end_date: budget_end)
      end
      return nil unless budget

      groups = BudgetCategory::Group.for(budget.budget_categories)

      {
        month: budget.to_param,
        period: {
          start_date: budget.start_date,
          end_date: budget.end_date
        },
        is_current: budget.current?,
        initialized: budget.initialized?,
        totals: {
          budgeted_spending: format_money(budget.budgeted_spending),
          allocated_spending: format_money(budget.allocated_spending),
          available_to_allocate: format_money(budget.available_to_allocate),
          actual_spending: format_money(budget.actual_spending),
          available_to_spend: format_money(budget.available_to_spend),
          percent_of_budget_spent: format_percent(budget.initialized? ? budget.percent_of_budget_spent : 0),
          overage_percent: format_percent(budget.overage_percent)
        },
        income: {
          expected_income: format_money(budget.expected_income),
          actual_income: format_money(budget.actual_income),
          remaining_expected_income: format_money((budget.expected_income || 0) - budget.actual_income)
        },
        categories: groups.map { |group| serialize_group(group, include_daily_suggestion: budget.current?) }
      }
    end

    def serialize_group(group, include_daily_suggestion:)
      parent = group.budget_category
      serialize_category(parent, include_daily_suggestion: include_daily_suggestion).merge(
        color: parent.category.color,
        subcategories: group.budget_subcategories.map do |sub|
          serialize_category(sub, include_daily_suggestion: include_daily_suggestion).merge(
            inherits_parent_budget: sub.inherits_parent_budget?
          )
        end
      )
    end

    def serialize_category(bc, include_daily_suggestion:)
      payload = {
        name: bc.name,
        budgeted: format_money(bc.display_budgeted_spending),
        actual: format_money(bc.actual_spending),
        available: format_money(bc.available_to_spend),
        percent_spent: format_percent(bc.percent_of_budget_spent || 0),
        status: category_status(bc)
      }

      if include_daily_suggestion
        suggestion = bc.suggested_daily_spending
        payload[:suggested_daily_spending] = suggestion[:amount].format if suggestion
      end

      payload
    end

    def category_status(bc)
      return "over_budget" if bc.over_budget_with_budget?
      return "unbudgeted" if bc.unbudgeted_with_spending?
      return "near_limit" if bc.budgeted? && bc.near_limit?
      return "on_track" if bc.on_track?
      "no_activity"
    end

    def resolve_month_start(raw)
      base = parse_month(raw)
      return (base || Date.current).beginning_of_month unless family.uses_custom_month_start?

      # Match Budget.param_to_date for explicit slugs so the input round-trips with the response.
      base ? Date.new(base.year, base.month, family.month_start_day) : family.custom_month_start_for(Date.current)
    end

    def parse_month(raw)
      return nil if raw.blank?

      # Date.strptime ignores trailing characters, so guard with strict anchors first.
      fmt = case raw
      when /\A\d{4}-\d{2}\z/         then "%Y-%m"
      when /\A[A-Za-z]{3}-\d{4}\z/   then "%b-%Y"
      end

      raise Assistant::Error, "Invalid month: #{raw}. Use YYYY-MM or MMM-YYYY." if fmt.nil?

      Date.strptime(raw, fmt)
    rescue ArgumentError
      raise Assistant::Error, "Invalid month: #{raw}. Use YYYY-MM or MMM-YYYY."
    end

    def shift_months(date, n)
      shifted = date >> n
      if family.uses_custom_month_start?
        family.custom_month_start_for(shifted)
      else
        shifted.beginning_of_month
      end
    end

    def format_money(value)
      Money.new(value || 0, family.currency).format
    end

    def format_percent(value)
      number_to_percentage(value || 0, precision: 1)
    end
end
