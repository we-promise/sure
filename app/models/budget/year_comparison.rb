class Budget::YearComparison
  attr_reader :current_plan, :previous_plan

  def initialize(family, current_year:, previous_year: nil)
    previous_year ||= current_year - 1
    @current_plan = Budget::AnnualPlan.new(family, year: current_year)
    @previous_plan = Budget::AnnualPlan.new(family, year: previous_year)
  end

  def category_comparisons
    @category_comparisons ||= current_plan.category_summaries.map do |current_cs|
      previous_cs = previous_plan.category_summaries.find { |pcs| pcs.category.id == current_cs.category.id }

      CategoryComparison.new(
        category: current_cs.category,
        current_actual: current_cs.annual_actual,
        previous_actual: previous_cs&.annual_actual || 0,
        current_budget: current_cs.annual_budget,
        previous_budget: previous_cs&.annual_budget || 0,
        currency: current_plan.currency
      )
    end
  end

  def total_change_percent
    return 0 if previous_plan.total_annual_actual.zero?

    ((current_plan.total_annual_actual - previous_plan.total_annual_actual) / previous_plan.total_annual_actual.to_f * 100).round(1)
  end

  def improved_categories
    category_comparisons.select(&:improved?)
  end

  def worsened_categories
    category_comparisons.select(&:worsened?)
  end

  CategoryComparison = Data.define(:category, :current_actual, :previous_actual, :current_budget, :previous_budget, :currency) do
    def change_amount
      current_actual - previous_actual
    end

    def change_percent
      return 0 if previous_actual.zero?

      ((current_actual - previous_actual) / previous_actual.to_f * 100).round(1)
    end

    def improved?
      change_amount.negative?
    end

    def worsened?
      change_amount.positive?
    end

    def unchanged?
      change_amount.zero?
    end

    def name
      category.name
    end

    def color
      category.color
    end
  end
end
