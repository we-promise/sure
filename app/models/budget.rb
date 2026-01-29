class Budget < ApplicationRecord
  include Monetizable

  PARAM_DATE_FORMAT = "%b-%Y"

  belongs_to :family

  has_many :budget_categories, -> { includes(:category) }, dependent: :destroy

  validates :start_date, :end_date, presence: true
  validates :start_date, :end_date, uniqueness: { scope: :family_id }

  monetize :budgeted_spending, :expected_income, :allocated_spending,
           :actual_spending, :available_to_spend, :available_to_allocate,
           :estimated_spending, :estimated_income, :actual_income, :remaining_expected_income

  class << self
    def date_to_param(date)
      date.strftime(PARAM_DATE_FORMAT).downcase
    end

    def param_to_date(param)
      Date.strptime(param, PARAM_DATE_FORMAT).beginning_of_month
    end

    def budget_date_valid?(date, family:)
      beginning_of_month = date.beginning_of_month

      beginning_of_month >= oldest_valid_budget_date(family) && beginning_of_month <= Date.current.end_of_month
    end

    def find_or_bootstrap(family, start_date:)
      return nil unless budget_date_valid?(start_date, family: family)

      Budget.transaction do
        budget = Budget.find_or_create_by!(
          family: family,
          start_date: start_date.beginning_of_month,
          end_date: start_date.end_of_month
        ) do |b|
          b.currency = family.currency
        end

        budget.sync_budget_categories

        budget
      end
    end

    private
      def oldest_valid_budget_date(family)
        # Allow going back to either the earliest entry date OR 2 years ago, whichever is earlier
        two_years_ago = 2.years.ago.beginning_of_month
        oldest_entry_date = family.oldest_entry_date.beginning_of_month
        [ two_years_ago, oldest_entry_date ].min
      end
  end

  def period
    Period.custom(start_date: start_date, end_date: end_date)
  end

  def to_param
    self.class.date_to_param(start_date)
  end

  def sync_budget_categories
    current_category_ids = family.categories.expenses.pluck(:id).to_set
    existing_budget_category_ids = budget_categories.pluck(:category_id).to_set
    categories_to_add = current_category_ids - existing_budget_category_ids
    categories_to_remove = existing_budget_category_ids - current_category_ids

    # Create missing categories
    categories_to_add.each do |category_id|
      budget_categories.create!(
        category_id: category_id,
        budgeted_spending: 0,
        currency: family.currency
      )
    end

    # Remove old categories
    budget_categories.where(category_id: categories_to_remove).destroy_all if categories_to_remove.any?
  end

  def uncategorized_budget_category
    budget_categories.uncategorized.tap do |bc|
      bc.budgeted_spending = [ available_to_allocate, 0 ].max
      bc.currency = family.currency
    end
  end

  def transactions
    family.transactions.visible.in_period(period)
  end

  def name
    start_date.strftime("%B %Y")
  end

  def initialized?
    budgeted_spending.present?
  end

  def income_category_totals
    income_totals.category_totals.reject { |ct| ct.category.subcategory? || ct.total.zero? }.sort_by(&:weight).reverse
  end

  def expense_category_totals
    expense_totals.category_totals.reject { |ct| ct.category.subcategory? || ct.total.zero? }.sort_by(&:weight).reverse
  end

  # Returns expense category totals WITH savings contributions included as a virtual category
  # This recalculates weights to include savings as part of total expenses
  def expense_category_totals_with_savings
    base_totals = expense_category_totals
    savings_amount = allocated_to_goals
    return base_totals if savings_amount <= 0

    # Calculate new total including savings
    total_with_savings = base_totals.sum(&:total) + savings_amount

    # Recalculate weights for existing categories
    adjusted_totals = base_totals.map do |ct|
      new_weight = total_with_savings.zero? ? 0 : (ct.total.to_f / total_with_savings) * 100
      IncomeStatement::CategoryTotal.new(
        category: ct.category,
        total: ct.total,
        currency: ct.currency,
        weight: new_weight
      )
    end

    # Add savings as a virtual category total
    savings_weight = total_with_savings.zero? ? 0 : (savings_amount.to_f / total_with_savings) * 100
    savings_category_total = IncomeStatement::CategoryTotal.new(
      category: Category.savings,
      total: savings_amount,
      currency: currency,
      weight: savings_weight
    )

    (adjusted_totals + [savings_category_total]).sort_by(&:weight).reverse
  end

  # Actual spending INCLUDING savings contributions
  def actual_spending_with_savings
    actual_spending + allocated_to_goals
  end

  monetize :actual_spending_with_savings

  def current?
    start_date == Date.today.beginning_of_month && end_date == Date.today.end_of_month
  end

  def previous_budget_param
    previous_date = start_date - 1.month
    return nil unless self.class.budget_date_valid?(previous_date, family: family)

    self.class.date_to_param(previous_date)
  end

  def next_budget_param
    return nil if current?

    next_date = start_date + 1.month
    return nil unless self.class.budget_date_valid?(next_date, family: family)

    self.class.date_to_param(next_date)
  end

  def to_donut_segments_json
    unused_segment_id = "unused"
    savings_segment_id = "savings"

    # Continuous gray segment for empty budgets
    return [ { color: "var(--budget-unallocated-fill)", amount: 1, id: unused_segment_id } ] unless allocations_valid?

    segments = budget_categories.map do |bc|
      { color: bc.category.color, amount: budget_category_actual_spending(bc), id: bc.id }
    end

    # Add savings as a segment if there are savings contributions
    if allocated_to_goals > 0
      segments.push({ color: Category::SAVINGS_COLOR, amount: allocated_to_goals, id: savings_segment_id })
    end

    if available_to_spend.positive?
      segments.push({ color: "var(--budget-unallocated-fill)", amount: available_to_spend, id: unused_segment_id })
    end

    segments
  end

  # =============================================================================
  # Actuals: How much user has spent on each budget category
  # =============================================================================
  def estimated_spending
    income_statement.median_expense(interval: "month")
  end

  def actual_spending
    expense_totals.total
  end

  def budget_category_actual_spending(budget_category)
    expense_totals.category_totals.find { |ct| ct.category.id == budget_category.category.id }&.total || 0
  end

  def category_median_monthly_expense(category)
    income_statement.median_expense(category: category)
  end

  def category_avg_monthly_expense(category)
    income_statement.avg_expense(category: category)
  end

  def available_to_spend
    (budgeted_spending || 0) - actual_spending
  end

  # Budgeted spending INCLUDING savings commitment
  def budgeted_spending_with_savings
    (budgeted_spending || 0) + savings_commitment
  end

  monetize :budgeted_spending_with_savings

  # Available to spend INCLUDING savings
  def available_to_spend_with_savings
    budgeted_spending_with_savings - actual_spending_with_savings
  end

  monetize :available_to_spend_with_savings

  def percent_of_budget_spent
    return 0 unless budgeted_spending > 0

    (actual_spending / budgeted_spending.to_f) * 100
  end

  # Percent of budget spent INCLUDING savings
  def percent_of_budget_spent_with_savings
    return 0 unless budgeted_spending_with_savings > 0

    (actual_spending_with_savings / budgeted_spending_with_savings.to_f) * 100
  end

  # Overage percent INCLUDING savings
  def overage_percent_with_savings
    return 0 unless available_to_spend_with_savings.negative?

    available_to_spend_with_savings.abs / actual_spending_with_savings.to_f * 100
  end

  def overage_percent
    return 0 unless available_to_spend.negative?

    available_to_spend.abs / actual_spending.to_f * 100
  end

  # =============================================================================
  # Budget allocations: How much user has budgeted for all parent categories combined
  # =============================================================================
  def allocated_spending
    budget_categories.reject { |bc| bc.subcategory? }.sum(&:budgeted_spending)
  end

  def allocated_percent
    return 0 unless budgeted_spending && budgeted_spending > 0

    (allocated_spending / budgeted_spending.to_f) * 100
  end

  def available_to_allocate
    (budgeted_spending || 0) - allocated_spending
  end

  def allocations_valid?
    initialized? && available_to_allocate >= 0 && allocated_spending > 0
  end

  # =============================================================================
  # Income: How much user earned relative to what they expected to earn
  # =============================================================================
  def estimated_income
    family.income_statement.median_income(interval: "month")
  end

  def actual_income
    family.income_statement.income_totals(period: self.period).total
  end

  def actual_income_percent
    return 0 unless expected_income > 0

    (actual_income / expected_income.to_f) * 100
  end

  def remaining_expected_income
    expected_income - actual_income
  end

  def surplus_percent
    return 0 unless remaining_expected_income.negative?

    remaining_expected_income.abs / expected_income.to_f * 100
  end

  # =============================================================================
  # Savings Goals: Monthly surplus and allocations to goals
  # =============================================================================
  def monthly_surplus
    actual_income - actual_spending
  end

  monetize :monthly_surplus

  def allocated_to_goals
    SavingContribution
      .joins(:saving_goal)
      .where(saving_goals: { family_id: family_id })
      .where(month: start_date.beginning_of_month)
      .sum(:amount)
  end

  def available_for_goals
    [monthly_surplus - allocated_to_goals, 0].max
  end

  # Monthly commitment for all active goals with target dates
  # This is the amount that should be budgeted for savings each month
  def savings_commitment
    family_active_saving_goals
      .select { |g| g.monthly_target.present? && g.monthly_target > 0 }
      .sum(&:monthly_target)
  end

  monetize :savings_commitment

  # Amount of savings commitment that hasn't been funded this month
  def unfunded_savings_this_month
    [savings_commitment - allocated_to_goals, 0].max
  end

  # Adjusted surplus after accounting for savings commitment
  # This shows the "true" surplus after savings obligations
  def adjusted_surplus
    monthly_surplus - unfunded_savings_this_month
  end

  monetize :adjusted_surplus

  def family_active_saving_goals
    family.saving_goals.active.order(Arel.sql("target_date IS NULL, target_date ASC, created_at ASC"))
  end

  # Automatically fund active saving goals from budget surplus
  # Goals are funded in priority order (created_at ASC) up to their monthly target
  def auto_fund_saving_goals!
    contributions = []
    remaining = available_for_goals

    family_active_saving_goals.each do |goal|
      break if remaining <= 0
      next if goal.monthly_target.nil? || goal.monthly_target <= 0
      next if goal_already_funded_this_month?(goal)

      amount = [ goal.monthly_target, remaining ].min
      contribution = goal.saving_contributions.create!(
        amount: amount,
        currency: currency,
        month: start_date.beginning_of_month,
        source: "auto"
      )
      contributions << contribution
      remaining -= amount
    end

    contributions
  end

  def goal_already_funded_this_month?(goal)
    goal.saving_contributions.where(month: start_date.beginning_of_month).exists?
  end

  def goal_contribution_for_month(goal)
    goal.saving_contributions.find_by(month: start_date.beginning_of_month)
  end

  private
    def income_statement
      @income_statement ||= family.income_statement
    end

    def expense_totals
      @expense_totals ||= income_statement.expense_totals(period: period)
    end

    def income_totals
      @income_totals ||= family.income_statement.income_totals(period: period)
    end
end
