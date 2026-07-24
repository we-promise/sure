class Budget < ApplicationRecord
  include Monetizable

  PARAM_DATE_FORMAT = "%b-%Y"

  attr_accessor :current_user

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

    def param_to_date(param, family: nil)
      base_date = Date.strptime(param, PARAM_DATE_FORMAT)
      if family&.uses_custom_month_start?
        Date.new(base_date.year, base_date.month, family.month_start_day)
      else
        base_date.beginning_of_month
      end
    end

    def budget_date_valid?(date, family:)
      budget_start, _ = period_for(date, family: family)
      budget_start >= oldest_valid_budget_date(family) &&
        budget_start <= latest_valid_budget_start_date(family)
    end

    def period_for(date, family:)
      if family.uses_custom_month_start?
        [ family.custom_month_start_for(date), family.custom_month_end_for(date) ]
      else
        [ date.beginning_of_month, date.end_of_month ]
      end
    end

    def find_or_bootstrap(family, start_date:, user: nil)
      return nil unless budget_date_valid?(start_date, family: family)

      Budget.transaction do
        budget_start, budget_end = period_for(start_date, family: family)

        budget = Budget.find_or_create_by!(
          family: family,
          start_date: budget_start,
          end_date: budget_end
        ) do |b|
          b.currency = family.currency
        end

        budget.current_user = user
        budget.sync_budget_categories

        budget
      end
    end

    private
      def oldest_valid_budget_date(family)
        two_years_ago = 2.years.ago.beginning_of_month
        oldest_entry_date = family.oldest_entry_date.beginning_of_month
        [ two_years_ago, oldest_entry_date ].min
      end

      def latest_valid_budget_start_date(family)
        if family.uses_custom_month_start?
          family.current_custom_month_period.start_date + 2.years
        else
          Date.current.beginning_of_month + 2.years
        end
      end
  end

  def period
    Period.custom(start_date: start_date, end_date: end_date)
  end

  def to_param
    self.class.date_to_param(start_date)
  end

  def sync_budget_categories
    # Category changes can leave the association memoized before this sync runs.
    current_categories_by_id = family.categories.reload.index_by(&:id)
    current_category_ids = current_categories_by_id.keys.to_set
    existing_budget_category_ids = budget_categories.pluck(:category_id).to_set
    categories_to_add = current_category_ids - existing_budget_category_ids
    categories_to_remove = existing_budget_category_ids - current_category_ids

    # Create missing categories
    categories_to_add.each do |category_id|
      budget_categories.create!(
        category: current_categories_by_id.fetch(category_id),
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
    scope = family.transactions.visible.in_period(period)
    if current_user
      scope = scope.joins(:entry).where(entries: { account_id: family.accounts.accessible_by(current_user).included_in_reports.select(:id) })
    end
    scope
  end

  def name
    if family.uses_custom_month_start?
      I18n.t(
        "budgets.name.custom_range",
        start: I18n.l(start_date, format: :short),
        end_date: I18n.l(end_date, format: :long)
      )
    else
      I18n.t("budgets.name.month_year", month: I18n.l(start_date, format: :month_year))
    end
  end

  def initialized?
    budgeted_spending.present?
  end

  def most_recent_initialized_budget
    family.budgets
      .includes(:budget_categories)
      .where("start_date < ?", start_date)
      .where.not(budgeted_spending: nil)
      .order(start_date: :desc)
      .first
  end

  def copy_from!(source_budget)
    raise ArgumentError, "source budget must belong to the same family" unless source_budget.family_id == family_id
    raise ArgumentError, "source budget must precede target budget" unless source_budget.start_date < start_date

    Budget.transaction do
      update!(
        budgeted_spending: source_budget.budgeted_spending,
        expected_income: source_budget.expected_income
      )

      target_by_category = budget_categories.index_by(&:category_id)

      source_budget.budget_categories.each do |source_bc|
        target_bc = target_by_category[source_bc.category_id]
        next unless target_bc

        target_bc.update!(budgeted_spending: source_bc.budgeted_spending)
      end
    end
  end

  def income_category_totals
    net_totals.net_income_categories.reject { |ct| ct.total.zero? }.sort_by(&:weight).reverse
  end

  def expense_category_totals
    net_totals.net_expense_categories.reject { |ct| ct.total.zero? }.sort_by(&:weight).reverse
  end

  def current?
    if family.uses_custom_month_start?
      current_period = family.current_custom_month_period
      start_date == current_period.start_date && end_date == current_period.end_date
    else
      start_date == Date.current.beginning_of_month && end_date == Date.current.end_of_month
    end
  end

  # Whole days from today through the period's last day (today counts).
  # 0 once the period is over. Also feeds
  # BudgetCategory#suggested_daily_spending's per-day split.
  def days_remaining
    [ (end_date - Date.current).to_i + 1, 0 ].max
  end

  # Biggest parent categories by what's actually been spent this period,
  # falling back to allocation size early in the month before spending
  # lands. Categories with neither spend nor an allocation are noise in a
  # summary. (The budget_categories association preloads :category.)
  def top_spending_categories(limit: 4)
    budget_categories
      .reject(&:subcategory?)
      .reject { |bc| bc.actual_spending.to_d.zero? && bc.budgeted_spending.to_d.zero? }
      .sort_by { |bc| [ -bc.actual_spending.to_d, -bc.budgeted_spending.to_d ] }
      .first(limit)
  end

  def previous_budget_param
    previous_date = start_date - 1.month
    return nil unless self.class.budget_date_valid?(previous_date, family: family)

    self.class.date_to_param(previous_date)
  end

  def next_budget_param
    next_date = start_date + 1.month
    return nil unless self.class.budget_date_valid?(next_date, family: family)

    self.class.date_to_param(next_date)
  end

  def to_donut_segments_json
    unused_segment_id = "unused"

    # Continuous gray segment for empty budgets
    return [ { color: "var(--budget-unallocated-fill)", amount: 1, id: unused_segment_id } ] unless allocations_valid?

    segments = budget_categories.reject(&:subcategory?).map do |bc|
      { color: bc.category.color, amount: budget_category_actual_spending(bc), id: bc.id }
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
    net_totals.total_net_expense
  end

  def budget_category_actual_spending(budget_category)
    key = budget_category.category_id || stable_synthetic_key(budget_category.category)
    expense = expense_totals_by_category[key]&.total || 0
    refund = income_totals_by_category[key]&.total || 0
    [ expense - refund, 0 ].max
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

  def percent_of_budget_spent
    return 0 unless budgeted_spending > 0

    (actual_spending / budgeted_spending.to_f) * 100
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

  private
    def income_statement
      @income_statement ||= family.income_statement(user: current_user)
    end

    def net_totals
      @net_totals ||= income_statement.net_category_totals(period: period)
    end

    def expense_totals
      @expense_totals ||= income_statement.expense_totals(period: period)
    end

    def income_totals
      @income_totals ||= income_statement.income_totals(period: period)
    end

    def expense_totals_by_category
      @expense_totals_by_category ||= expense_totals.category_totals.index_by { |ct| ct.category.id || stable_synthetic_key(ct.category) }
    end

    def income_totals_by_category
      @income_totals_by_category ||= income_totals.category_totals.index_by { |ct| ct.category.id || stable_synthetic_key(ct.category) }
    end

    def stable_synthetic_key(category)
      if category.uncategorized?
        :uncategorized
      elsif category.other_investments?
        :other_investments
      end
    end
end
