class Budget::AnnualPlan
  attr_reader :family, :year

  def initialize(family, year: Date.current.year)
    @family = family
    @year = year
  end

  # All monthly budgets in the year
  def budgets
    @budgets ||= family.budgets
      .where(start_date: year_range)
      .includes(budget_categories: :category)
      .to_a
  end

  # Non-monthly budget categories with positive annual amounts
  def non_monthly_categories
    latest_budget.budget_categories
      .select(&:non_monthly?)
      .select { |bc| bc.annual_amount&.positive? }
  end

  # All top-level categories with annual plan data
  def category_summaries
    @category_summaries ||= latest_budget.budget_categories
      .reject(&:subcategory?)
      .reject { |bc| bc.budgeted_spending.zero? && (bc.annual_amount.nil? || bc.annual_amount.zero?) }
      .map { |bc| CategorySummary.new(bc, self) }
      .sort_by { |cs| -cs.annual_budget }
  end

  def expense_category_summaries
    category_summaries.reject { |cs| cs.budget_category.savings? }
  end

  def savings_category_summaries
    category_summaries.select { |cs| cs.budget_category.savings? }
  end

  def non_monthly_category_summaries
    category_summaries.select { |cs| cs.budget_category.non_monthly? }
  end

  def monthly_category_summaries
    category_summaries.reject { |cs| cs.budget_category.non_monthly? }
  end

  # Totals
  def total_annual_budget
    category_summaries.sum(&:annual_budget)
  end

  def total_annual_actual
    ytd_expense_totals.total
  end

  def total_annual_remaining
    total_annual_budget - total_annual_actual
  end

  def percent_complete
    return 0 unless total_annual_budget.positive?

    [ (total_annual_actual / total_annual_budget.to_f * 100).round(1), 100 ].min
  end

  def months_elapsed
    return 12 if year < Date.current.year
    return 0 if year > Date.current.year

    Date.current.month
  end

  def on_track?
    return true if total_annual_budget.zero?

    expected_spend = total_annual_budget * months_elapsed / 12.0
    total_annual_actual <= expected_spend
  end

  # Monthly amortized total
  def monthly_set_aside
    return 0 unless total_annual_budget.positive?

    total_annual_budget / 12.0
  end

  # Income for the year
  def annual_income
    ytd_income_totals.total
  end

  # Savings rate: (income - expenses) / income
  def savings_rate
    return 0 if annual_income.zero?

    ((annual_income - total_annual_actual) / annual_income.to_f * 100).round(1)
  end

  # Projected annual savings based on YTD pace
  def projected_annual_savings
    return 0 if months_elapsed.zero?

    ytd_savings = annual_income - total_annual_actual
    (ytd_savings / months_elapsed.to_f * 12).round(2)
  end

  def currency
    family.currency
  end

  def previous_year
    year - 1
  end

  def next_year
    year + 1
  end

  def can_go_previous?
    oldest_date = family.oldest_entry_date
    return false unless oldest_date

    previous_year >= oldest_date.year
  end

  def can_go_next?
    next_year <= Date.current.year
  end

  private

    def year_range
      Date.new(year, 1, 1)..Date.new(year, 12, 31)
    end

    def latest_budget
      @latest_budget ||= begin
        target_date = if year == Date.current.year
          Date.current.beginning_of_month
        else
          Date.new(year, 12, 1)
        end

        Budget.find_or_bootstrap(family, start_date: target_date) ||
          family.budgets.where(start_date: year_range).order(start_date: :desc).first ||
          Budget.find_or_bootstrap(family, start_date: Date.current.beginning_of_month)
      end
    end

    def ytd_period
      @ytd_period ||= begin
        year_start = Date.new(year, 1, 1)
        year_end = if year == Date.current.year
          Date.current
        else
          Date.new(year, 12, 31)
        end

        Period.custom(start_date: year_start, end_date: year_end)
      end
    end

    def income_statement
      @income_statement ||= family.income_statement
    end

    def ytd_expense_totals
      @ytd_expense_totals ||= income_statement.expense_totals(period: ytd_period)
    end

    def ytd_income_totals
      @ytd_income_totals ||= income_statement.income_totals(period: ytd_period)
    end

    # Inner class wrapping a budget_category with annual computed values
    class CategorySummary
      attr_reader :budget_category, :annual_plan

      delegate :category, :name, :non_monthly?, :budget_frequency, :savings?, to: :budget_category

      def initialize(budget_category, annual_plan)
        @budget_category = budget_category
        @annual_plan = annual_plan
      end

      def annual_budget
        if budget_category.non_monthly? && budget_category.annual_amount&.positive?
          budget_category.annual_amount
        else
          budget_category.budgeted_spending * 12
        end
      end

      def annual_actual
        budget_category.annual_actual_spending
      end

      def annual_remaining
        annual_budget - annual_actual
      end

      def percent_used
        return 0 unless annual_budget.positive?

        (annual_actual / annual_budget.to_f * 100).round(1)
      end

      def monthly_amortized
        return 0 unless annual_budget.positive?

        annual_budget / 12.0
      end

      def status
        return :over_budget if percent_used > 100
        return :warning if percent_used > 80
        :on_track
      end

      def frequency_label
        case budget_frequency
        when "annual" then "Annual"
        when "semi_annual" then "Semi-Annual"
        when "quarterly" then "Quarterly"
        else "Monthly"
        end
      end

      def color
        category.color
      end

      def currency
        annual_plan.currency
      end
    end
end
