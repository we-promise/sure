class BudgetCategory < ApplicationRecord
  include Monetizable

  belongs_to :budget
  belongs_to :category

  validates :budget_id, uniqueness: { scope: :category_id }

  monetize :budgeted_spending, :available_to_spend, :avg_monthly_expense, :median_monthly_expense, :actual_spending

  class Group
    attr_reader :budget_category, :budget_subcategories

    delegate :category, to: :budget_category
    delegate :name, :color, to: :category

    def self.for(budget_categories)
      top_level_categories = budget_categories.select { |budget_category| budget_category.category.parent_id.nil? }
      top_level_categories.map do |top_level_category|
        subcategories = budget_categories.select { |bc| bc.category.parent_id == top_level_category.category_id && top_level_category.category_id.present? }
        new(top_level_category, subcategories.sort_by { |subcategory| subcategory.category.name })
      end.sort_by { |group| group.category.name }
    end

    def initialize(budget_category, budget_subcategories = [])
      @budget_category = budget_category
      @budget_subcategories = budget_subcategories
    end
  end

  class << self
    def uncategorized
      new(
        id: Digest::UUID.uuid_v5(Digest::UUID::URL_NAMESPACE, "uncategorized"),
        category: nil,
      )
    end
  end

  def initialized?
    budget.initialized?
  end

  def category
    super || budget.family.categories.uncategorized
  end

  def name
    category.name
  end

  def actual_spending
    budget.budget_category_actual_spending(self)
  end

  def avg_monthly_expense
    budget.category_avg_monthly_expense(category)
  end

  def median_monthly_expense
    budget.category_median_monthly_expense(category)
  end

  def subcategory?
    category.parent_id.present?
  end

  # Returns true if this subcategory has no individual budget limit and should use parent's budget
  def inherits_parent_budget?
    subcategory? && (self[:budgeted_spending].nil? || self[:budgeted_spending] == 0)
  end

  # Returns the budgeted spending to display in UI
  # For inheriting subcategories, returns the parent's budget for reference
  def display_budgeted_spending
    if inherits_parent_budget?
      parent = parent_budget_category
      return 0 unless parent
      parent[:budgeted_spending] || 0
    else
      self[:budgeted_spending] || 0
    end
  end

  # Returns the parent budget category if this is a subcategory
  def parent_budget_category
    return nil unless subcategory?
    @parent_budget_category ||= budget.budget_categories.find { |bc| bc.category.id == category.parent_id }
  end

  def available_to_spend
    if inherits_parent_budget?
      # Subcategories using parent budget share the parent's available_to_spend
      parent = parent_budget_category
      return 0 unless parent
      parent.available_to_spend
    elsif subcategory?
      # Subcategory with individual limit
      (self[:budgeted_spending] || 0) - actual_spending
    else
      # Parent category
      parent_budget = self[:budgeted_spending] || 0

      # Get subcategories with and without individual limits
      subcategories_with_limits = subcategories.reject(&:inherits_parent_budget?)

      # Ring-fenced budgets for subcategories with individual limits
      subcategories_individual_budgets = subcategories_with_limits.sum { |sc| sc[:budgeted_spending] || 0 }

      # Shared pool = parent budget - ring-fenced budgets
      shared_pool = parent_budget - subcategories_individual_budgets

      # Get actual spending from income statement (includes all subcategories)
      total_spending = actual_spending

      # Subtract spending from subcategories with individual budgets (they use their ring-fenced money)
      subcategories_with_limits_spending = subcategories_with_limits.sum(&:actual_spending)

      # Spending from shared pool = total spending - ring-fenced spending
      shared_pool_spending = total_spending - subcategories_with_limits_spending

      # Available in shared pool
      shared_pool - shared_pool_spending
    end
  end

  def percent_of_budget_spent
    if inherits_parent_budget?
      # For subcategories using parent budget, show their spending as percentage of parent's budget
      parent = parent_budget_category
      return 0 unless parent

      parent_budget = parent[:budgeted_spending] || 0
      return 0 if parent_budget == 0 && actual_spending == 0
      return 100 if parent_budget == 0 && actual_spending > 0
      (actual_spending.to_f / parent_budget) * 100
    else
      budget_amount = self[:budgeted_spending] || 0
      return 0 if budget_amount == 0 && actual_spending == 0
      return 0 if budget_amount > 0 && actual_spending == 0
      return 100 if budget_amount == 0 && actual_spending > 0
      (actual_spending.to_f / budget_amount) * 100 if budget_amount > 0 && actual_spending > 0
    end
  end

  def bar_width_percent
    [ percent_of_budget_spent, 100 ].min
  end

  def over_budget?
    available_to_spend.negative?
  end

  def near_limit?
    !over_budget? && percent_of_budget_spent >= 90
  end

  # Returns hash with suggested daily spending info or nil if not applicable
  def suggested_daily_spending
    return nil unless available_to_spend > 0

    budget_date = budget.start_date
    return nil unless budget_date.month == Date.current.month && budget_date.year == Date.current.year

    days_remaining = (budget_date.end_of_month - Date.current).to_i + 1
    return nil unless days_remaining > 0

    {
      amount: Money.new((available_to_spend / days_remaining), budget.family.currency),
      days_remaining: days_remaining
    }
  end

  def to_donut_segments_json
    unused_segment_id = "unused"
    overage_segment_id = "overage"

    return [ { color: "var(--budget-unallocated-fill)", amount: 1, id: unused_segment_id } ] unless actual_spending > 0

    segments = [ { color: category.color, amount: actual_spending, id: id } ]

    if available_to_spend.negative?
      segments.push({ color: "var(--color-destructive)", amount: available_to_spend.abs, id: overage_segment_id })
    else
      segments.push({ color: "var(--budget-unallocated-fill)", amount: available_to_spend, id: unused_segment_id })
    end

    segments
  end

  def siblings
    budget.budget_categories.select { |bc| bc.category.parent_id == category.parent_id && bc.id != id }
  end

  def max_allocation
    return nil unless subcategory?

    parent_budget_cat = budget.budget_categories.find { |bc| bc.category.id == category.parent_id }
    return nil unless parent_budget_cat

    parent_budget = parent_budget_cat[:budgeted_spending] || 0

    # Sum budgets of siblings that have individual limits (excluding those that inherit)
    siblings_with_limits = siblings.reject(&:inherits_parent_budget?)
    siblings_budget = siblings_with_limits.sum { |s| s[:budgeted_spending] || 0 }

    [ parent_budget - siblings_budget, 0 ].max
  end

  def subcategories
    return BudgetCategory.none unless category.parent_id.nil?

    budget.budget_categories
      .joins(:category)
      .where(categories: { parent_id: category.id })
  end
end
