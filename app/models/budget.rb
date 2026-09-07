class Budget < ApplicationRecord
  include Monetizable

  PARAM_DATE_FORMAT = "%b-%Y"

  attr_accessor :current_user

  # Overrides the account scope `income_statement` would otherwise infer.
  # Budget::RolloverCalculator sets it on the household chain: the carry it
  # stores is one shared row, so it must not be computed through whichever
  # viewer's account access happened to trigger the recompute.
  attr_writer :income_statement_accounts

  belongs_to :family
  belongs_to :user, optional: true

  has_many :budget_categories, -> { includes(:category) }, dependent: :destroy

  validates :start_date, :end_date, presence: true
  validates :start_date, :end_date, uniqueness: { scope: [ :family_id, :user_id ] }

  monetize :available_cash, :earmarked_for_goals, :free_cash
  monetize :budgeted_spending, :expected_income, :allocated_spending,
           :actual_spending, :available_to_spend, :available_to_allocate,
           :estimated_spending, :estimated_income, :actual_income, :remaining_expected_income,
           :total_rolled_over

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

    # `household: true` explicitly requests the shared household budget
    # (user_id NULL) regardless of `user:` — this is what lets a household
    # budget and personal budgets coexist once `family.personal_budgets?` is
    # on. Without it, `user:` resolves to that user's personal budget when
    # personal_budgets is on, or the shared budget otherwise (unchanged
    # behavior for families that never turned personal budgets on).
    #
    # Returns nil if the household budget was explicitly requested but the
    # family opted out of it via `household_budget_enabled?`.
    def find_or_bootstrap(family, start_date:, user: nil, household: false)
      return nil unless budget_date_valid?(start_date, family: family)
      return nil if household && family.personal_budgets? && !family.household_budget_enabled?

      Budget.transaction do
        budget_start, budget_end = period_for(start_date, family: family)

        owner = (household || !family.personal_budgets?) ? nil : user

        budget = Budget.find_or_create_by!(
          family: family,
          start_date: budget_start,
          end_date: budget_end,
          user: owner
        ) do |b|
          b.currency = family.currency
        end

        budget.current_user = user
        budget.sync_budget_categories

        Budget::RolloverCalculator.new(family: family, user: owner).recompute!

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
    inherited_rollover = inherited_rollover_flags(categories_to_add)

    categories_to_add.each do |category_id|
      budget_categories.create!(
        category: current_categories_by_id.fetch(category_id),
        budgeted_spending: 0,
        currency: family.currency,
        rollover_enabled: inherited_rollover.fetch(category_id, false)
      )
    end

    # Remove old categories
    budget_categories.where(category_id: categories_to_remove).destroy_all if categories_to_remove.any?
  end

  # Rollover is a standing choice about an envelope, not about one month: a
  # user who switches it on for Vacations expects it to keep going, and a
  # month bootstrapped with the flag off would silently break the chain. New
  # rows therefore inherit it from the last initialized budget of the same
  # owner -- the same chain the carry itself walks. Turning it off on a given
  # month still overrides it from there on.
  def inherited_rollover_flags(category_ids)
    return {} if category_ids.empty?

    source = most_recent_initialized_budget
    return {} unless source

    source.budget_categories
      .where(category_id: category_ids, rollover_enabled: true)
      .each_with_object({}) { |bc, flags| flags[bc.category_id] = true }
  end

  def uncategorized_budget_category
    budget_categories.uncategorized.tap do |bc|
      bc.budgeted_spending = [ available_to_allocate, 0 ].max
      bc.currency = family.currency
    end
  end

  # Personal budgets only ever reflect the owner's own accounts, regardless
  # of who's viewing (a shared read-only/read-write viewer sees the owner's
  # numbers, not their own accessible accounts). The household budget keeps
  # the pre-personal-budgets behavior: whatever the requesting viewer can
  # see, since it has no single owner to scope by.
  def transactions
    scope = family.transactions.visible.in_period(period)

    if user_id.present?
      scope = scope.joins(:entry).where(entries: { account_id: family.accounts.where(owner_id: user_id).included_in_reports.select(:id) })
    elsif current_user
      scope = scope.joins(:entry).where(entries: { account_id: family.accounts.accessible_by(current_user).included_in_reports.select(:id) })
    end

    scope
  end

  # --- Cash on hand, next to the plan ---
  #
  # DELIBERATELY OUTSIDE the allocation arithmetic. `budgeted_spending`,
  # `allocated_spending` and `available_to_allocate` keep their exact meaning:
  # they answer "what did I plan to spend, and how much of it have I
  # distributed". These three answer a different question — "what do I actually
  # have" — and mixing the two is how a budget stops being readable. A page
  # showing "expected income 3,000" beside "really free 1,600" leaves the user
  # unsure which number drives the split.
  #
  # This is the whole of the compromise: the plan stays a forecast, and the
  # cash is shown beside it rather than folded into it.

  # Liquidity only. Cash held inside investment accounts (Account#cash_balance)
  # is deliberately out: it is not money available to this month's budget.
  #
  # Scoped like #transactions — a personal budget sees only its owner's
  # accounts, the household one what the viewer can see — because a figure
  # labelled "available" must mean available to the person reading it.
  def cash_accounts
    scope = family.accounts.visible.included_in_reports.where(accountable_type: "Depository")

    if user_id.present?
      scope.where(owner_id: user_id)
    elsif current_user
      scope.accessible_by(current_user)
    else
      scope
    end
  end

  def available_cash
    @available_cash ||= cash_accounts.sum { |account| convert_to_budget_currency(account.balance, account.currency) }
  end

  # What goals have already spoken for, out of THE SAME accounts. Restricting
  # to `cash_accounts` is the point: Goal::FUNDABLE_ACCOUNT_TYPES also includes
  # Investment, and subtracting an earmark held on a brokerage account from a
  # cash figure that never counted it would show a "really free" amount that is
  # too low — or negative — with nothing on the page to explain why.
  #
  # Built from the shared pool rather than summing allocated_amount, because a
  # whole-account link reserves no fixed slice and would otherwise count as
  # zero while actually claiming the remainder.
  def earmarked_for_goals
    @earmarked_for_goals ||= begin
      ids = cash_accounts.map(&:id)

      if ids.empty?
        0.to_d
      else
        # Converted per goal. `available_cash` converts each account balance
        # into the budget currency, so summing backings in their own would
        # subtract euros from dollars: a fully earmarked EUR 1,000 account in
        # a USD budget would read 1,200 available, 1,000 earmarked and 200
        # free, when none of it is free.
        Goal.prepared_for(family, scope: family.goals.where.not(state: Goal::RELEASED_STATES))
            .sum { |goal| convert_to_budget_currency(goal.backing_within(ids), goal.currency) }
      end
    end
  end

  def free_cash
    [ available_cash - earmarked_for_goals, 0 ].max
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

  # The household budget (user_id nil) is visible/editable by every family
  # member, matching pre-personal_budgets behavior. A personal budget is
  # only visible/editable by its owner, or by someone the owner shared it
  # with via BudgetShare.
  def viewable_by?(user)
    return true if user_id.nil?
    return true if user_id == user.id

    BudgetShare.exists?(owner_id: user_id, viewer_id: user.id)
  end

  def editable_by?(user)
    return true if user_id.nil?
    return true if user_id == user.id

    BudgetShare.exists?(owner_id: user_id, viewer_id: user.id, permission: "read_write")
  end

  def most_recent_initialized_budget
    family.budgets
      .includes(:budget_categories)
      .where("start_date < ?", start_date)
      .where.not(budgeted_spending: nil)
      .where(user_id: user_id)
      .order(start_date: :desc)
      .first
  end

  def copy_from!(source_budget)
    raise ArgumentError, "source budget must belong to the same family" unless source_budget.family_id == family_id
    raise ArgumentError, "source budget must belong to the same user" unless source_budget.user_id == user_id
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

        # The toggle is a preference and travels with the copy; the amount
        # is derived state that only Budget::RolloverCalculator may write.
        target_bc.update!(
          budgeted_spending: source_bc.budgeted_spending,
          rollover_enabled: source_bc.rollover_enabled
        )
      end

      # Copying the toggle changes what the chain should hold, and this runs
      # after find_or_bootstrap already recomputed it. Recompute again so the
      # target doesn't sit on a zero carry until the next page load.
      Budget::RolloverCalculator.new(family: family, user: user).recompute!
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

    segments = donut_budget_categories.map do |bc|
      { color: bc.category.color, amount: budget_category_actual_spending(bc), id: bc.id }
    end

    if available_to_spend.positive?
      segments.push({ color: "var(--budget-unallocated-fill)", amount: available_to_spend, id: unused_segment_id })
    end

    segments
  end

  def donut_budget_categories
    categories = budget_categories.reject(&:subcategory?).to_a
    uncategorized = uncategorized_budget_category

    if budget_category_actual_spending(uncategorized).positive?
      categories << uncategorized
    end

    categories
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

  # Informational aggregate only -- deliberately kept out of
  # `allocated_spending` and `available_to_allocate`, which stay a pure
  # "what did I plan to spend this month" pair. Ring-fenced subcategories
  # carry their own surplus and their parent's is net of theirs, so summing
  # every non-inheriting category counts each amount once.
  def total_rolled_over
    budget_categories.reject(&:inherits_parent_budget?).sum(&:rolled_over_amount)
  end

  def allocations_valid?
    initialized? && available_to_allocate >= 0 && allocated_spending > 0
  end

  # =============================================================================
  # Income: How much user earned relative to what they expected to earn
  # =============================================================================
  def estimated_income
    income_statement.median_income(interval: "month")
  end

  def actual_income
    income_statement.income_totals(period: self.period).total
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
    # `find_or_fetch_rate`, not `find_rate` — the latter does not exist, and
    # every multi-currency family opening this page hit a NoMethodError.
    #
    # No rate for the day leaves the amount as it stands. A cash panel that
    # renders with one figure unconverted is wrong by the spread; one that
    # raises takes the whole budget page down with it.
    def convert_to_budget_currency(amount, from_currency)
      return amount.to_d if from_currency == currency

      rate = ExchangeRate.find_or_fetch_rate(from: from_currency, to: currency, date: Date.current)&.rate
      rate ? amount.to_d * rate : amount.to_d
    end
    def income_statement
      @income_statement ||= family.income_statement(user: current_user, accounts: income_statement_accounts)
    end

    # nil for the household budget (IncomeStatement falls back to whatever
    # `current_user` can see, unchanged pre-personal-budgets behavior). For a
    # personal budget, restrict to the owner's own accounts so a shared
    # viewer sees the owner's numbers, and household vs. personal actually
    # differ instead of both reflecting the viewer's full accessible set.
    def income_statement_accounts
      return @income_statement_accounts if @income_statement_accounts

      family.accounts.where(owner_id: user_id).included_in_reports if user_id.present?
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
