# Bills subsystem: exposes what this category's bills have already committed
# inside the budget period, as a read-side hook only.
class BudgetCategory < ApplicationRecord
  # Money this category's bills still expect inside the budget period --
  # committed but not yet spent. Read-side only: budgets stay derived from
  # posted entries, and debt-payment transfers never reach here because
  # transfer series carry no category.
  def bills_reserved
    bills_reservation.first
  end

  # Obligations in this period with no rate into the budget currency. Counted
  # and reported rather than dropped: a reservation that silently omits money
  # reads as money the user still has free to spend.
  def bills_reserved_unconvertible_count
    bills_reservation.last
  end

  include Monetizable

  belongs_to :budget
  belongs_to :category

  validates :budget_id, uniqueness: { scope: :category_id }

  monetize :budgeted_spending, :available_to_spend, :avg_monthly_expense, :median_monthly_expense, :actual_spending,
           :rolled_over_amount

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

    # Moves `amount` of allocation from one envelope to another in a single
    # step — YNAB's "roll with the punches". Deliberately keeps no history:
    # v1 stores the resulting allocations, nothing else.
    #
    # ⚠️ Does NOT recompute the rollover chain, on purpose. The caller must
    # run Budget::RolloverCalculator AFTER this returns, never inside it:
    # the calculator takes a transaction-scoped advisory lock, and taking it
    # while these row locks are held inverts the lock order every other
    # caller uses (update_budgeted_spending! commits before the calculator
    # runs). Two concurrent moves would then deadlock — one holding rows and
    # waiting for the advisory lock, the other holding the advisory lock and
    # waiting for those rows.
    def move_allocation!(from:, to:, amount:)
      amount = amount.to_d
      validate_move!(from: from, to: to, amount: amount)

      transaction do
        # Deterministic lock order — the critical detail of this operation.
        # update_budgeted_spending! locks its own row and, for a
        # subcategory, its parent. Two simultaneous moves in opposite
        # directions would each hold what the other wants, so every row this
        # touches is locked up front, by ascending id.
        where(id: lock_ids_for_move(from, to)).order(:id).lock.to_a

        from.reload
        to.reload

        # Re-checked under the lock: the balance read before it may be stale.
        raise InvalidMove.new(:insufficient_funds) if amount > movable_from(from)

        from.update_budgeted_spending!((from[:budgeted_spending] || 0) - amount)
        to.update_budgeted_spending!((to[:budgeted_spending] || 0) + amount)
      end

      [ from.reload, to.reload ]
    end

    private
      def validate_move!(from:, to:, amount:)
        raise InvalidMove.new(:non_positive_amount) unless amount.positive?
        # Checked before the budget comparison: "Uncategorized" is synthesized
        # on read and carries no budget_id, so it would otherwise be reported
        # as belonging to a different budget — true, but not the reason.
        raise InvalidMove.new(:uncategorized) if [ from, to ].any? { |bc| bc[:category_id].nil? || !bc.persisted? }
        raise InvalidMove.new(:different_budgets) unless from.budget_id == to.budget_id
        raise InvalidMove.new(:same_category) if from.id == to.id
        raise InvalidMove.new(:parent_child) if direct_lineage?(from, to)
        raise InvalidMove.new(:insufficient_funds) if amount > movable_from(from)
      end

      # What a category can actually send away. For a leaf that is its whole
      # allocation; for a parent it is only its own reserve, because
      # `budgeted_spending` on a parent ALREADY CONTAINS its individually
      # funded subcategories' allocations (sync_parent_budgeted_spending!
      # keeps it at children + reserve).
      #
      # Comparing against the gross figure let a move spend money that is
      # already ring-fenced by a child, leaving the parent below the sum of
      # its children — and the next edit to any child rebuilt the parent back
      # up, silently undoing the move. The money appeared to teleport back.
      def movable_from(budget_category)
        gross = budget_category[:budgeted_spending] || 0
        return gross if budget_category.subcategory?

        ring_fenced = budget_category.subcategories
                                     .reject(&:inherits_parent_budget?)
                                     .sum { |child| child[:budgeted_spending] || 0 }

        [ gross - ring_fenced, 0 ].max
      end

      # sync_parent_budgeted_spending! rebuilds a parent from the sum of its
      # children plus its own reserve, so money moved between a parent and
      # its direct child would be re-derived away and the "sum is conserved"
      # invariant would not hold. Refuse the move rather than special-case it.
      def direct_lineage?(from, to)
        from[:category_id] == to.category.parent_id || to[:category_id] == from.category.parent_id
      end

      # from, to, and whichever parents update_budgeted_spending! will touch.
      def lock_ids_for_move(from, to)
        parent_category_ids = [ from, to ].filter_map { |bc| bc.category.parent_id }
        parent_ids = if parent_category_ids.any?
          from.budget.budget_categories.where(category_id: parent_category_ids).pluck(:id)
        else
          []
        end

        ([ from.id, to.id ] + parent_ids).uniq
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

  # The toggle is a standing choice about the envelope, and the comment on
  # Budget#inherited_rollover_flags already says so: "turning it off on a given
  # month still overrides it from there on."
  #
  # Inheritance at row creation only covers months that do not exist yet. A
  # user who opened March, then went back to January and switched rollover on,
  # left March sitting at `false` — created before the choice was made, so it
  # never had one to inherit — and the chain died there. Applying the choice
  # forward closes that hole without a tri-state column: later months carry the
  # most recent decision, which is the one the user just made.
  def propagate_rollover_choice_forward!
    later = BudgetCategory
      .joins(:budget)
      .where(category_id: category_id)
      .where(budgets: { family_id: budget.family_id, user_id: budget.user_id })
      .where("budgets.start_date > ?", budget.start_date)
      .where.not(rollover_enabled: rollover_enabled)

    later.update_all(rollover_enabled: rollover_enabled, updated_at: Time.current)
  end

  def update_budgeted_spending!(new_budgeted_spending)
    self.class.transaction do
      lock!

      previous_budgeted_spending = budgeted_spending || 0
      update!(budgeted_spending: new_budgeted_spending)

      sync_parent_budgeted_spending!(previous_budgeted_spending:) if subcategory?
    end
  end

  # Raised by move_allocation! when the requested move is not one the budget
  # can represent. Carries an i18n key rather than a sentence so the
  # controller renders it localized.
  class InvalidMove < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(I18n.t("budget_categories.move.errors.#{reason}"))
    end
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

  # Materialized by Budget::RolloverCalculator, never derived on read. Going
  # through the toggle here (and skipping subcategories that share their
  # parent's budget) keeps every consumer consistent even if a stale amount
  # outlives the toggle that produced it.
  def rolled_over_amount
    return 0 unless rollover_enabled?
    return 0 if inherits_parent_budget?

    super || 0
  end

  def rolled_over?
    rolled_over_amount.positive?
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
      (self[:budgeted_spending] || 0) + rolled_over_amount - actual_spending
    else
      # Parent category
      parent_budget = (self[:budgeted_spending] || 0) + rolled_over_amount

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

  # Consumption, so it measures against everything there is to spend --
  # rollover included, which is what `available_to_spend` reports. (The
  # allocation figures, `allocated_spending` and `available_to_allocate`,
  # deliberately stay a pure "what did I plan for this month".) The
  # zero-budget guards below apply to that effective amount, not to the
  # allocation alone: a category funded only by rollover has money to spend.
  def percent_of_budget_spent
    if inherits_parent_budget?
      # For subcategories using parent budget, show their spending as percentage of parent's budget
      parent = parent_budget_category
      return 0 unless parent

      parent_budget = (parent[:budgeted_spending] || 0) + parent.rolled_over_amount
      return 0 if parent_budget == 0 && actual_spending == 0
      return 100 if parent_budget == 0 && actual_spending > 0
      (actual_spending.to_f / parent_budget) * 100
    else
      budget_amount = (self[:budgeted_spending] || 0) + rolled_over_amount
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

  # "Is there money in this envelope", which drives the over-budget /
  # on-track classification -- so it counts the carry too. Without it a
  # category funded entirely by rollover reads as unbudgeted, lands in
  # `unbudgeted_with_spending?` and gets an alert pill while it still has
  # money left. `display_budgeted_spending` stays the month's allocation
  # alone: the card shows the two figures side by side.
  def budgeted?
    (display_budgeted_spending.to_d + display_rolled_over_amount.to_d).positive?
  end

  # Sibling of `display_budgeted_spending`: a subcategory sharing its
  # parent's budget shares its parent's carry as well.
  def display_rolled_over_amount
    return rolled_over_amount unless inherits_parent_budget?

    parent_budget_category&.rolled_over_amount || 0
  end

  def unbudgeted_with_spending?
    !budgeted? && actual_spending.to_d.positive?
  end

  def over_budget_with_budget?
    budgeted? && over_budget?
  end

  def on_track?
    budgeted? && !over_budget?
  end

  def any_over_budget?
    unbudgeted_with_spending? || over_budget_with_budget?
  end

  def visible_on_track?
    return false unless on_track?

    # Subcategories inheriting parent budget are hidden until they have spending.
    return true unless subcategory? && inherits_parent_budget?

    actual_spending.to_d.positive?
  end

  def near_limit?
    !over_budget? && percent_of_budget_spent >= 90
  end

  # Returns hash with suggested daily spending info or nil if not applicable
  def suggested_daily_spending
    return nil unless available_to_spend > 0
    return nil unless budget.current?

    days_remaining = budget.days_remaining
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

  def subcategories
    return BudgetCategory.none unless category.parent_id.nil?
    return BudgetCategory.none if category.id.nil?

    budget.budget_categories
      .joins(:category)
      .where(categories: { parent_id: category.id })
  end

  private
    # A foreign-currency obligation is converted, not skipped: it is still owed
    # out of this category. Only one with no rate at all falls out, and that one
    # is counted.
    def bills_reservation
      @bills_reservation ||= begin
        occurrences = RecurringOccurrence
                        .open_status
                        .joins(:recurring_transaction)
                        .where(recurring_transactions: {
                                 family_id: budget.family_id,
                                 category_id: category_id,
                                 status: :active,
                                 destination_account_id: nil
                               })
                        .where("recurring_transactions.amount > 0")
                        .where(due_on: budget.start_date..budget.end_date)
                        .includes(:recurring_transaction)
                        .to_a

        # One grouped sum for the whole set. Reading remaining_amount straight
        # off each row issues a SUM per occurrence, which is a query count that
        # grows with the number of bills the user has.
        sums = RecurringAllocation.confirmed
                                  .where(recurring_occurrence_id: occurrences.map(&:id))
                                  .group(:recurring_occurrence_id)
                                  .sum(:allocated_amount)

        unconvertible = 0

        total = occurrences.reduce(Money.new(0, currency)) do |sum, occurrence|
          occurrence.cached_confirmed_allocated = sums.fetch(occurrence.id, 0)

          begin
            sum + occurrence.remaining_amount_money.exchange_to(currency)
          rescue Money::ConversionError
            unconvertible += 1
            sum
          end
        end

        [ total, unconvertible ]
      end
    end

    def sync_parent_budgeted_spending!(previous_budgeted_spending:)
      parent_budget_category = budget.budget_categories.where(category_id: category.parent_id).lock.first
      return unless parent_budget_category

      sibling_budgeted_spending = budget.budget_categories
        .joins(:category)
        .where(categories: { parent_id: category.parent_id })
        .where.not(id: id)
        .sum(:budgeted_spending)

      # Preserve positive parent reserve—the extra budget assigned directly to the parent
      # beyond the sum of its subcategories—but do not carry forward a negative reserve
      # that would leave the parent below its subcategory total.
      parent_budget_reserve = [
        (parent_budget_category.budgeted_spending || 0) - sibling_budgeted_spending - previous_budgeted_spending,
        0
      ].max

      parent_budget_category.update!(
        budgeted_spending: sibling_budgeted_spending + (budgeted_spending || 0) + parent_budget_reserve
      )
    end
end
