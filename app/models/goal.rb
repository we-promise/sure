class Goal < ApplicationRecord
  include AASM, Monetizable

  COLORS = Category::COLORS
  ICONS = Category.icon_codes

  # States in which a goal has let go of its money: `Goal.pooled_allocations_for`
  # leaves it out of the backing math, so its links reserve nothing and the
  # account it pointed at is free again.
  #
  # Read by three places that must agree — the shared pool, GoalAccount's
  # exclusivity check, and the restore guard below. Keeping them on one constant
  # is what stops the double-counting hole from reopening the day this set
  # grows: adding a state here makes every one of them release together.
  #
  # `completed` belongs here for the same reason `archived` does: completing a
  # goal hands back the earmark, so its links must stop reserving too.
  RELEASED_STATES = %w[archived completed].freeze

  validates :icon, inclusion: { in: ICONS, allow_nil: true }
  validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }, allow_nil: true

  belongs_to :family
  # autosave so earmark (allocated_amount) edits on already-linked accounts
  # persist through goal.save! — without it Rails only saves newly built
  # children, silently dropping changes to existing goal_accounts.
  has_many :goal_accounts, dependent: :destroy, autosave: true
  has_many :linked_accounts, through: :goal_accounts, source: :account
  has_many :goal_pledges, dependent: :destroy
  has_many :open_pledges,
           -> { where(status: "open").where("expires_at >= ?", Time.current) },
           class_name: "GoalPledge"

  validates :name, presence: true, length: { maximum: 255 }
  validates :target_amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true
  # before_save (not before_validation) so it only mutates on persistence, not
  # on every valid? call — a goal can be inspected without its basis flipping.
  before_save :default_progress_basis_for_investment
  # A reserve measured in months is derived, not typed: computing it only in
  # the monthly job would leave a brand-new one wrong until the 1st, so the
  # feature's first impression would be its least convincing moment. Fired on
  # creation and whenever the inputs change — never on an unrelated save, so
  # the job keeps owning the monthly cadence and renaming a goal cannot
  # silently move a financial figure.
  # A target_amount edit is in the list because in this mode the amount is
  # derived, not typed: without it the form could persist an arbitrary figure
  # under a "six months of expenses" label until the next monthly refresh.
  # before_VALIDATION, not before_save. `target_amount` is required and must be
  # positive, and those run before any save callback — so a reserve whose
  # amount is derived arrived at validation empty and was refused before the
  # callback that fills it ever ran. The form makes the field read-only in this
  # mode, so there was no way to satisfy the validation by hand either: the
  # months mode could not be created from the UI at all.
  before_validation :apply_months_of_expenses_target,
                    if: -> {
                      months_of_expenses_target? && (
                        new_record? ||
                        target_months_changed? ||
                        target_mode_changed? ||
                        target_amount_changed?
                      )
                    }

  validate :must_have_at_least_one_linked_account
  validate :linked_accounts_must_be_fundable
  validate :linked_accounts_must_match_goal_currency
  validate :linked_accounts_must_belong_to_family
  validate :currency_locked_once_linked
  validate :restore_must_not_recreate_whole_account_conflict
  validate :kind_locked_while_released
  validate :kind_locked_once_consumed
  validate :target_must_cover_what_was_consumed
  # A reserve has no deadline. Normalising here rather than rejecting: the form
  # hides the field for a reserve, so a date can only arrive from a conversion
  # or a crafted request — refusing would show an error about a field the user
  # cannot see.
  before_validation :clear_target_date_for_maintained

  # Autosave validates each link separately, so each would otherwise take its
  # own account lock in association order. Two goals saving links on the same
  # two accounts in opposite orders would then hold one lock each and wait on
  # the other. Taking the whole set here, sorted, before any child validates,
  # is what makes the order the same for everyone.
  before_validation :lock_whole_account_claims_in_order

  # AASM's event `after` hooks run on the non-bang form too, which does not
  # save. `goal.complete` therefore left the row `active` in the database
  # while stamping it with a completion snapshot — a goal still being funded,
  # carrying a frozen amount and a completion date. Everything downstream that
  # keys off `completed_amount.present?` then read it as closed.
  #
  # Hung off the persisted change instead, so the side effects and the state
  # they belong to are the same fact. Still inside the save transaction, so a
  # later failure takes both back.
  after_save :apply_state_change_side_effects, if: :saved_change_to_state?

  monetize :target_amount

  # Account types that can back a goal (see linked_accounts_must_be_fundable).
  FUNDABLE_ACCOUNT_TYPES = %w[Depository Investment].freeze

  # States in which a goal has let go of the money it was holding, and so
  # drops out of the shared pool. `completed` belongs here: reaching a goal
  # is the moment its earmark stops competing with its siblings on the same
  # account — that is what "done" means for money.
  #
  # `paused` is deliberately absent. Pausing means "I have stopped feeding
  # this", not "I have released it"; a paused goal keeps its reservation.
  #
  # ⚠️ Four places filter on this and must agree, or free_to_earmark will
  # contradict the pool: here, Account#goal_earmarked_total,
  # GoalAccount#whole_account_link_must_be_exclusive (through
  # Goal#whole_account_conflicts_on), and the restore guard
  # #restore_must_not_recreate_whole_account_conflict, which reads the same
  # method. Adding a state here makes all of them release together.
  # Raised by #consume!. Carries a reason so the controller can say WHICH rule
  # refused rather than "something went wrong" — every one of them is
  # actionable by the user.
  class ConsumptionRefused < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super("goal consumption refused: #{reason}")
    end
  end

  # A one-off goal is reached once and then closed; a maintained one is a
  # floor to hold — an emergency fund is not an achievement to file away, it
  # is a level to keep. The two differ in what 100% means, whether `complete`
  # is even allowed, and how they sort.
  KINDS = %w[one_off maintained].freeze

  # How a reserve's floor is expressed. "6 months of expenses" is a moving
  # number — what covers six months in January is not what covers six months
  # in December — so RefreshMaintainedGoalTargetsJob rewrites `target_amount`
  # monthly. `target_amount` stays the single source of truth on purpose:
  # every aggregate that reads it (remaining_amount, progress_percent,
  # Goal.summary_for, the ring, the card) keeps working untouched, where an
  # effective_target_amount would have to be threaded through all of them.
  TARGET_MODES = %w[fixed months_of_expenses].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :target_mode, inclusion: { in: TARGET_MODES }
  validates :target_months, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :months_target_requires_a_reserve

  # Display order for active (non-completed/non-archived) goals: whatever
  # needs money first, then on-track, then open-ended, then the reserves that
  # are already whole. Paused sorts after all of these.
  #
  # `depleted` shares rank 0 with `behind`: a reserve below its floor is the
  # same kind of "this needs attention" as a goal off pace. `active_display_sort`
  # falls back to 4 for anything unranked, so omitting these two would bury a
  # drained emergency fund at the very bottom of the list — the exact opposite
  # of what it means.
  ACTIVE_DISPLAY_STATUS_RANK = { behind: 0, depleted: 0, on_track: 1, no_target_date: 2, funded: 3 }.freeze

  scope :alphabetically, -> { order(Arel.sql("LOWER(name) ASC")) }
  scope :active_first, lambda {
    order(Arel.sql("CASE state WHEN 'active' THEN 0 WHEN 'paused' THEN 1 WHEN 'completed' THEN 2 ELSE 3 END"))
  }

  # Family-wide map of live goal earmarks, grouped by account_id:
  # { account_id => [{ goal_id:, allocated_amount: }, ...] }. The controller
  # assigns this to each goal on index (goal.pooled_allocations = ...) so the
  # shared-pool backing math runs ONE query for the whole page instead of one
  # per goal.
  def self.pooled_allocations_for(family)
    GoalAccount.joins(:goal)
               .where(goals: { family_id: family.id })
               .where.not(goals: { state: RELEASED_STATES })
               .pluck(:account_id, :goal_id, :allocated_amount)
               .group_by(&:first)
               .transform_values do |triples|
                 triples.map { |(_, goal_id, amount)| { goal_id: goal_id, allocated_amount: amount } }
               end
  end

  # Whole-account links held by OTHER goals of this family on any of
  # `account_ids` — the links that would double-count the balance if this goal
  # claimed one of those accounts in full too.
  #
  # Shared by GoalAccount's exclusivity validation (which asks about the one
  # account being written) and by the restore guard (which asks about every
  # account this goal claims in full). One query, one scope: the two cannot
  # drift into disagreeing about what "already claimed" means.
  # `excluding_link_id` is the row being written, when there is one. Excluding
  # by goal alone is not enough for a link that is CHANGING goals: its persisted
  # row still carries the old goal_id, so the query hands it back and the link
  # conflicts with itself.
  # A whole-account claim is exclusive per account, and the check that enforces
  # it is a read. Callers take this first so the read and the write that
  # follows are one step as far as any other request is concerned.
  def self.lock_whole_account_claims!(account_id)
    # Bound rather than interpolated. The key is a digest of an id and could
    # not carry a payload, but a hand-built SQL string in a model is the shape
    # a reader has to stop and verify — and Brakeman flags it, correctly.
    # Projected through a subquery so the result set is an integer, not the
    # `void` the lock function returns — which the adapter cannot type and
    # logs a warning about on every acquisition.
    connection.exec_query(
      "SELECT 1 FROM (SELECT pg_advisory_xact_lock($1)) locked",
      "Goal Whole-Account Claim Lock",
      [ ActiveRecord::Relation::QueryAttribute.new(
          "key", whole_account_claim_lock_key(account_id), ActiveRecord::Type::BigInteger.new
        ) ]
    )
  end

  def self.whole_account_claim_lock_key(account_id)
    Digest::SHA1.hexdigest("goal_accounts:whole_account:#{account_id}").to_i(16) % (2**63)
  end

  def whole_account_conflicts_on(account_ids, excluding_link_id: nil)
    ids = Array(account_ids).compact
    return GoalAccount.none if ids.empty?

    # Serialised before the read, because what follows is a check-then-write:
    # two requests can both find no conflict and both commit a whole-account
    # claim, recreating exactly the double-count this exists to prevent. A
    # transaction-scoped advisory lock rather than a row lock — the conflicting
    # write may be an INSERT, so there is no row to lock — and it is released
    # when the enclosing transaction ends, whichever way it ends.
    #
    # Locked in id order so two goals claiming the same pair of accounts in
    # opposite orders cannot deadlock against each other. Saving a goal takes
    # the whole set up front (see `lock_whole_account_claims_in_order`); this
    # covers a link saved on its own, and re-taking a lock the transaction
    # already holds costs nothing.
    ids.sort.each { |account_id| self.class.lock_whole_account_claims!(account_id) }

    scope = GoalAccount.joins(:goal)
                       .where(account_id: ids, allocated_amount: nil)
                       .where(goals: { family_id: family_id })
                       .where.not(goals: { state: RELEASED_STATES })

    scope = scope.where.not(goal_id: id) if persisted?
    scope = scope.where.not(id: excluding_link_id) if excluding_link_id
    scope
  end

  attr_writer :pooled_allocations

  # Family-wide map of cumulative market gain/loss per account_id (sum of
  # balances.net_market_flows). Injected on index alongside pooled_allocations
  # so contributions-basis goals don't fire one Balance aggregate per account
  # per goal (N+1).
  def self.market_flows_for(family)
    account_ids = GoalAccount.joins(:goal).where(goals: { family_id: family.id }).distinct.pluck(:account_id)
    return {} if account_ids.empty?

    Balance.where(account_id: account_ids).group(:account_id).sum(:net_market_flows)
  end

  attr_writer :market_flows

  # Family-wide map of each linked account's net inflow over the trailing
  # 90 days (account_id => net Entry#amount sum) — the same aggregate #pace
  # computes per goal. Injected alongside pooled_allocations/market_flows so
  # sorting/rendering N goals (active_display_sort calls goal.status, which
  # reaches #pace for any goal with a target_date) fires one grouped query
  # instead of one Entry.sum per goal.
  def self.pace_for(family)
    account_ids = GoalAccount.joins(:goal).where(goals: { family_id: family.id }).distinct.pluck(:account_id)
    return {} if account_ids.empty?

    Entry
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(account_id: account_ids, date: 90.days.ago.to_date..Date.current)
      .where(excluded: false)
      .merge(Transaction.excluding_pending)
      .group(:account_id)
      .sum(:amount)
  end

  attr_writer :pooled_pace

  # Goals loaded ready to render: association preloads for the card/row
  # partials plus the family-wide pooled-allocations + market-flows injection
  # so the per-goal backing math doesn't fire a query per row (N+1). Pass a
  # narrower scope to limit which of the family's goals are loaded.
  def self.prepared_for(family, scope: family.goals)
    goals = scope.alphabetically
                 .includes(:open_pledges, :goal_accounts, linked_accounts: :account_providers)
                 .to_a
    inject_backing_math!(goals, family)
    goals
  end

  # One family-wide earmark-pool + market-flows + pace read shared across
  # every goal in the list (see pooled_allocations_for / market_flows_for /
  # pace_for).
  def self.inject_backing_math!(goals, family)
    pooled = pooled_allocations_for(family)
    flows = market_flows_for(family)
    pace_map = pace_for(family)
    goals.each do |goal|
      goal.pooled_allocations = pooled
      goal.market_flows = flows
      goal.pooled_pace = pace_map
    end
  end

  # Display order shared by the goals index and the Plan hub: behind first,
  # then on-track, then open-ended, paused last, name as tie-breaker.
  # Paused sorts last, behind every ranked status and the unranked fallback.
  # It used to share rank 3 with :funded, so a paused goal whose name sorted
  # first jumped ahead of a reserve that was whole — the list claiming the
  # paused one wanted attention more.
  PAUSED_DISPLAY_RANK = 5

  def self.active_display_sort(goals)
    goals.sort_by do |goal|
      rank = goal.paused? ? PAUSED_DISPLAY_RANK : ACTIVE_DISPLAY_STATUS_RANK.fetch(goal.status, 4)
      [ rank, goal.name.downcase ]
    end
  end

  # Active goals ready to render outside the goals index (e.g. the Plan hub).
  def self.active_prepared_for(family)
    active_display_sort(
      prepared_for(family, scope: family.goals.where.not(state: %w[completed archived]))
    )
  end

  # Aggregates for a summary card over an already-prepared goal list. Money
  # sums only make sense in one currency, so goals denominated differently
  # stay in the caller's row list but out of the totals.
  def self.summary_for(goals, currency:)
    summable = goals.select { |goal| goal.currency == currency }
    targeted = summable.select { |goal| goal.target_amount.to_d.positive? }

    {
      saved_money: Money.new(summable.sum { |goal| goal.current_balance.to_d }, currency),
      target_money: Money.new(targeted.sum { |goal| goal.target_amount.to_d }, currency),
      behind_count: goals.count(&:behind_pace?),
      pending_count: goals.sum { |goal| goal.open_pledges.size }
    }
  end

  aasm column: :state do
    after_all_transitions :reset_state_dependent_caches!

    state :active, initial: true
    state :paused
    state :completed
    state :archived

    event :pause do
      transitions from: :active, to: :paused
    end

    event :resume do
      transitions from: :paused, to: :active
    end

    # Guarded to one_off: completing releases the earmark, and releasing the
    # money is the opposite of what a reserve is for. A maintained goal at
    # 100% is simply whole; there is nothing to close.
    event :complete do
      transitions from: [ :active, :paused ], to: :completed, guard: :one_off?
    end

    event :archive do
      transitions from: [ :active, :paused, :completed ], to: :archived
    end

    event :unarchive do
      transitions from: :archived, to: :active
    end

    event :reopen do
      transitions from: :completed, to: :active
    end
  end

  # Balance is this goal's backing across its linked depository accounts that
  # match the goal's currency. Each linked account contributes either its
  # earmarked slice (goal_accounts.allocated_amount) or — when unallocated —
  # the whole balance left after other goals' earmarks (see
  # #backing_balance_for). The model validates the currency invariant at write
  # time, but the defensive filter + telemetry here guards against drift from
  # direct DB writes, account-currency edits outside goal validation, or
  # future code that bypasses the validation chain.
  def current_balance
    # A closed goal reports what it reached, not what its accounts hold now.
    # The guard is `present?`, never `completed?`: `archive` accepts a goal
    # straight from active or paused, so an archived goal that was never
    # completed has no frozen amount and keeps the live calculation. Both
    # shapes coexist in the database.
    return completed_amount.to_d if completed_amount.present?

    @current_balance ||= begin
      matching = linked_accounts.select { |a| a.currency == currency }
      if matching.size != linked_accounts.size
        Rails.logger.warn("Goal##{id} linked-account currency drift: #{linked_accounts.size - matching.size} of #{linked_accounts.size} mismatched (expected #{currency})")
        Sentry.capture_message("Goal linked-account currency drift", level: :warning, extra: { goal_id: id, expected_currency: currency }) if defined?(Sentry)
      end
      matching.sum { |account| account_amount_for(account) }
    end
  end

  def current_balance_money
    @current_balance_money ||= Money.new(current_balance, currency)
  end

  # This goal's backing from a single linked account — the earmarked slice, or
  # the whole-balance remainder when the link is unallocated — as Money. Used
  # by the funding breakdown so the per-account rows reconcile with the ring.
  # This goal's backing drawn from a specific set of accounts, in its own
  # currency. Used by the budget to ask "how much of THESE accounts is already
  # spoken for" without counting a link held on an account outside the set.
  #
  # Goes through the same `backing_share_for` as everything else, so a
  # whole-account link is counted for the remainder it actually claims rather
  # than the zero its nil allocation would suggest.
  def backing_within(account_ids)
    ids = Array(account_ids).to_set
    linked_accounts
      .select { |account| account.currency == currency && ids.include?(account.id) }
      .sum { |account| account_amount_for(account) }
  end

  # Whether this reader can record a spend against this goal. Two doors lead to
  # the same dialog — the lifecycle panel and the overflow menu — and they have
  # to agree: offering it on the strength of money the reader cannot reach ends
  # in a dialog with nothing to pick and a refusal on submit.
  def spendable_within?(account_ids)
    one_off? && active? && backing_within(account_ids).to_d.positive?
  end

  def account_backing(account)
    Money.new(account_amount_for(account), currency)
  end

  def contributions_basis?
    progress_basis == "contributions"
  end

  def one_off?
    kind == "one_off"
  end

  def maintained?
    kind == "maintained"
  end

  def months_of_expenses_target?
    target_mode == "months_of_expenses"
  end

  # Recomputes this reserve's floor from the family's median monthly spend.
  # Returns the new amount when it wrote one, nil when it deliberately did
  # not — a family with no spending history yet, or a figure that would
  # violate the `target_amount > 0` check constraint. Leaving the previous
  # target standing is the safe failure: it is a number the user has been
  # saving against, where zero would silently declare the reserve complete.
  def refresh_target_from_expenses!
    computed = months_of_expenses_amount
    return nil if computed.nil? || computed == target_amount.to_d

    update!(target_amount: computed)
    computed
  end

  # Whether a months-based target could be worked out AT ALL right now. The
  # form has to know before the user has picked anything, so this deliberately
  # ignores the goal's own kind, mode and months: it answers "is there spending
  # history to derive from", nothing else. With none, the typed amount is the
  # only way to set a target, so the form must keep offering the field.
  def months_target_derivable?
    return false if family.nil? || currency.blank?

    median = median_monthly_expense
    return false unless median.positive?

    convert_to_goal_currency(median).to_d.positive?
  end

  private
    # The family's median monthly spend, in FAMILY currency.
    #
    # ⚠️ The account scope is passed EXPLICITLY, and that is the whole point
    # of this method. IncomeStatement's constructor does `user || Current.user`
    # and narrows to that user's accounts, so calling it bare gives a
    # family-wide figure only by accident — when no user happens to be
    # current, i.e. from a background job. `target_amount` is shared by the
    # whole family: derived from a viewer's slice of the accounts it would
    # change depending on who last triggered it. The rollover chain hit
    # exactly this and had to be pinned the same way.
    # Deliberately not memoized. The refresh job derives again on an instance
    # it has already saved through, and a median frozen on first read would
    # hand it back the figure it started with.
    def median_monthly_expense
      IncomeStatement.new(family, accounts: family.accounts.visible.included_in_reports)
                     .median_expense(interval: "month").to_d
    end

    # The balance this reserve should hold, or nil when it cannot be computed.
    def months_of_expenses_amount
      return nil unless maintained? && months_of_expenses_target? && target_months.to_i.positive?

      median = median_monthly_expense
      return nil unless median.positive?

      computed = (median * target_months).round(2)
      return nil unless computed.positive?

      # The median comes back in FAMILY currency; `target_amount` is stored in
      # the GOAL's. A EUR reserve in a USD family would otherwise read a 3,000
      # dollar floor as 3,000 euros, and rewrite it that way every month.
      converted = convert_to_goal_currency(computed)
      converted&.positive? ? converted : nil
    end

    # nil when there is no rate for the day. That is the same safe failure as
    # a family with no spending history: the previous target stands, because
    # it is a number the user has been saving against and a wrong one is worse
    # than a stale one.
    def convert_to_goal_currency(amount)
      return amount if currency == family.currency

      Money.new(amount, family.currency).exchange_to(currency).amount.round(2)
    rescue Money::ConversionError
      nil
    end

  public

  # Market value of the goal's backing (balance basis), regardless of the
  # progress basis — the "what it's worth today" figure shown next to
  # contributions on an investment-backed goal.
  def market_value_money
    amount = linked_accounts.select { |a| a.currency == currency }.sum { |a| backing_share_for(a, a.balance.to_d) }
    Money.new(amount, currency)
  end

  # What is still to be found. Money already SPENT on the thing the goal was
  # for counts as found: it did its job. Without that term, coming home from
  # the holiday a goal paid for dropped it from 100% to 20%, and the only way
  # back was to edit the target — falsifying what the user had set out to save.
  def remaining_amount
    @remaining_amount ||= [ target_amount - current_balance - consumed_amount.to_d, 0 ].max
  end

  # Records that `amount` was spent on the thing this goal was for.
  #
  # Two things happen, and the second is the one that is easy to miss: the
  # earmark on the account shrinks by the same amount. Without that, money the
  # user has already spent stays reserved, and keeps its share of the account
  # away from every sibling goal — the very double-counting the exclusivity
  # rules exist to prevent, arriving through the back door.
  #
  # `account:` may be omitted only when the goal has one link. With several,
  # guessing would silently pick a side; the caller has to say which pot the
  # money came out of.
  # `transaction:` anchors the record on the outflow it came from. Without one
  # this is a bare declaration and nothing stops it being made twice; with one,
  # the transaction is stamped and a second attempt on the same outflow is
  # refused. Same `extra["goal"]` namespace the pledges already write into, so
  # the two halves of a goal's money — in and out — are stamped alike.
  def consume!(amount, account: nil, transaction: nil)
    amount = amount.to_d
    raise ConsumptionRefused.new(:non_positive) unless amount.positive?
    # A reserve is not consumed, it is drawn down and refilled. Spending from
    # one leaves a shortfall to close, which `remaining_amount` already reports
    # on its own; recording it as consumption would erase exactly the signal
    # the reserve exists to give.
    raise ConsumptionRefused.new(:maintained) if maintained?

    link = consumption_link_for(account)

    # The GOAL is locked, not just the link. `consumed_amount` lives here, and
    # two concurrent requests locking only their own links would both read the
    # same old value, both pass the target check, and both add to it — the
    # goal ending up consumed past its target with neither request at fault.
    # The checks below therefore run under the lock, on freshly read values.
    with_lock do
      raise ConsumptionRefused.new(:not_active) unless active?
      raise ConsumptionRefused.new(:exceeds_target) if consumed_amount.to_d + amount > target_amount.to_d

      link.lock!
      stamp_consumption!(transaction) if transaction

      if link.allocated_amount.present?
        # Refused rather than clamped. Clamping released only what the link
        # held while `consumed_amount` took the full figure, so the two sides
        # silently disagreed: money counted as spent that was never released,
        # and still reserved against every sibling goal on the account.
        if amount > link.allocated_amount.to_d
          raise ConsumptionRefused.new(:exceeds_earmark)
        end

        link.update!(allocated_amount: link.allocated_amount.to_d - amount)
      else
        # A whole-account link has no slice to shrink, so `consumed_amount`
        # would be added to a backing that has not moved: the goal reads 6,000
        # of 5,000 until the real transaction lands and the balance catches up.
        # A fixed earmark never has that window, because shrinking it caps the
        # backing straight away.
        #
        # Spending settles what the link claims. It stops taking "whatever is
        # there" and takes what the goal still needs after this spend.
        #
        # Deliberately NOT "what it backs, minus the amount". That depends on
        # whether the money has already left the account, and the app cannot
        # know: a spend recorded before the sync lands needs the subtraction,
        # the same spend recorded after it has already had one, and taking it
        # twice reports 4,000 of a 5,000 goal that is whole. Capping at what
        # is left to reach is the same answer in both orders, with nothing to
        # infer.
        backed = backing_within([ link.account_id ]).to_d

        # Same refusal a fixed earmark gives, for the same reason: the link
        # cannot have supplied money it never backed. `still_needed` cannot go
        # negative — the target check above has already refused that.
        raise ConsumptionRefused.new(:exceeds_earmark) if amount > backed

        still_needed = target_amount.to_d - consumed_amount.to_d - amount
        link.update!(allocated_amount: [ backed, still_needed ].min)
      end

      update!(consumed_amount: consumed_amount.to_d + amount)
    end

    # `reload` refreshes the columns and leaves the memos standing. Consuming
    # moves the same balance-derived figures a transition does — and shrinks a
    # link's allocation, so the pooled-allocation memo goes with them.
    reload
    reset_state_dependent_caches!
    self
  end

  def remaining_amount_money
    @remaining_amount_money ||= Money.new(remaining_amount, currency)
  end

  # What progress actually counts: money still held for the goal, plus money
  # already taken out of it and spent on the thing it was for.
  #
  # `progress_percent` and `remaining_amount` have always been computed from
  # both. Only the headline figure showed the first half, so a goal that had
  # spent part of its savings sat at a 100% ring beside "3,000 of 5,000" — the
  # ring and the numbers disagreeing on the same card, with nothing to explain
  # which one to believe.
  def progress_amount
    current_balance.to_d + consumed_amount.to_d
  end

  def progress_amount_money
    @progress_amount_money ||= Money.new(progress_amount, currency)
  end

  def consumed_amount_money
    @consumed_amount_money ||= Money.new(consumed_amount.to_d, currency)
  end

  # Only a goal that has actually recorded a spend says anything about it: the
  # overwhelming majority never do, and a permanent "0 used" line would be
  # noise on every card.
  def any_consumption?
    consumed_amount.to_d.positive?
  end

  def progress_percent
    return @progress_percent if defined?(@progress_percent)

    @progress_percent = if completed?
      100
    elsif target_amount.to_d.zero?
      0
    elsif remaining_amount.to_d.zero?
      100
    else
      (((current_balance.to_d + consumed_amount.to_d) / target_amount.to_d) * 100).floor.clamp(0, 99)
    end
  end

  # Day-precision so the near-deadline cliff doesn't kick in: at
  # calendar-month precision, May 30 → June 1 returned 1 ("save $5k this
  # month") then June 1 → June 1 returned 0 (falls through to
  # "remaining_amount in one month"). Now a 2-day-out deadline reports
  # ~0.07 months and `monthly_target_amount` scales accordingly.
  def months_remaining
    return nil unless target_date

    days = (target_date - Date.current).to_i
    [ (days / 30.0), 0.0 ].max
  end

  def monthly_target_amount
    return @monthly_target_amount if defined?(@monthly_target_amount)

    @monthly_target_amount = if target_date.nil?
      nil
    elsif months_remaining.zero?
      remaining_amount
    else
      (remaining_amount.to_d / months_remaining.to_d).ceil(2)
    end
  end

  # 90-day rolling monthly pace: net inflow into linked accounts divided by
  # three months. Transfers between linked accounts net to zero (both sides
  # land inside this account set). Transfers from outside (e.g. checking
  # into linked savings) net positive, which is the behaviour we want: the
  # user records a pledge, the transfer arrives, balance goes up, pace
  # goes up, status flips off "behind". Excludes user-flagged-excluded
  # entries. Entry amount sign convention in Sure: inflow is negative.
  #
  # NOTE: pace is whole-account inflow by design in this phase, even for an
  # earmarked goal whose current_balance is only a slice — so runway/status
  # mix a whole-account numerator with an earmark-scoped balance. Earmark-aware
  # pace is a deliberate follow-up; don't "fix" the basis without that work.
  def pace
    return @pace if defined?(@pace)

    @pace = if linked_accounts.empty?
      0
    else
      net = linked_accounts.sum { |account| pooled_pace.fetch(account.id, 0).to_d }
      (-net.to_d / 3).round(2)
    end
  end

  def pace_money
    @pace_money ||= Money.new(pace, currency)
  end

  # Months of cash on hand at current pace (open-ended goals).
  def months_of_runway
    return nil if target_date.present?
    return nil if pace.zero? || pace.negative?

    (current_balance.to_d / pace.to_d).round(1)
  end

  def to_donut_segments_json
    filled = current_balance.to_d
    rem = remaining_amount.to_d

    if filled.zero? && rem.zero?
      return [ { color: "var(--budget-unused-fill)", amount: 1, id: "unused" } ]
    end

    segments = []
    segments << { color: color.presence || "var(--color-blue-500)", amount: filled, id: "saved" } if filled.positive?
    segments << { color: "var(--budget-unused-fill)", amount: rem, id: "unused" } if rem.positive?
    segments
  end

  # 90-day balance trajectory of linked accounts. Used by the projection chart
  # to render the saved-to-date line. Returns an empty series when the linked
  # account lacks ≥30 days of history. Ships pre-formatted labels for the
  # static chart annotations (target line, projection-end / shortfall,
  # pending-pledge badge) so the Stimulus controller only has to render
  # strings server-side rather than build them with its own Intl calls.
  def projection_payload
    series_values = balance_series_values
    # The historical series tracks the whole linked-account balances. Scale it
    # to this goal's backing so the saved line meets current_balance at "today"
    # instead of dropping off a cliff for earmarked goals. Assumes the earmark
    # ratio held over the window (an approximation); exact for unallocated
    # goals, where ratio == 1 and the series is unchanged.
    whole_total = linked_accounts.select { |a| a.currency == currency }.sum { |a| a.balance.to_d }
    # 0 when the linked-account total is non-positive: current_balance is forced
    # to 0 there, so the saved series must end at 0 too (no stray non-zero tail).
    #
    # Capped at 1 because `current_balance` no longer tracks the accounts once a
    # goal is closed: it returns the amount frozen at completion. Spend those
    # accounts afterwards and the ratio runs away — a frozen 4,000 over a live
    # 100 scales every historical point by fifty, drawing a chart that never
    # happened. The goal's share of its accounts cannot exceed all of them.
    backing_ratio = whole_total.positive? ? (current_balance.to_d / whole_total) : 0.to_d
    backing_ratio = 1.to_d if backing_ratio > 1
    saved_series = series_values.map { |v| { date: v.date.to_s, value: (v.value.amount.to_d * backing_ratio).to_f } }

    earliest = series_values.first&.date || created_at.to_date
    target_amt = target_amount.to_d
    proj_end = projection_end_amount

    {
      saved_series: saved_series,
      start_date: earliest.to_s,
      today: Date.current.to_s,
      target_date: target_date&.to_s,
      target_amount: target_amt.to_f,
      target_amount_label: Money.new(target_amt, currency).format(precision: 0),
      target_amount_short_label: short_money(target_amt, currency),
      currency_symbol: Money.new(0, currency).currency.symbol,
      current_amount: current_balance.to_f,
      avg_monthly: pace.to_f,
      required_monthly: monthly_target_amount&.to_f,
      currency: currency,
      status: status.to_s,
      projection_end_value: proj_end.to_f,
      projection_end_label: Money.new(proj_end, currency).format(precision: 0),
      projection_shortfall_label: (target_amt > proj_end ? Money.new(target_amt - proj_end, currency).format(precision: 0) : nil)
    }
  end

  # Projected balance at the target_date given the current pace. Mirrors
  # the JS calculation so the server can pre-format the chart annotation
  # without re-rendering after each Stimulus draw.
  def projection_end_amount
    return current_balance.to_d if target_date.nil?
    months = ((target_date - Date.current).to_f / 30.44).clamp(0.0, Float::INFINITY)
    projected = current_balance.to_d + (pace.to_d * months)
    [ current_balance.to_d, projected ].max
  end

  def display_status
    return @display_status if defined?(@display_status)

    @display_status = if archived?
      :archived
    elsif paused?
      :paused
    elsif completed?
      :completed
    else
      status
    end
  end

  # :reached         → completed, or no remaining amount
  # :on_track        → has target_date and pace >= required monthly
  # :behind          → has target_date and pace < required monthly
  # :no_target_date  → open-ended
  def status
    return @status if defined?(@status)

    # A reserve is never "reached": sitting at its floor is its steady state,
    # not an achievement to file away. It is either whole or short.
    return @status = (remaining_amount.to_d.zero? ? :funded : :depleted) if maintained?

    @status = if completed? || remaining_amount.to_d.zero?
      :reached
    elsif target_date.nil?
      :no_target_date
    elsif monthly_target_amount.to_d <= pace.to_d
      :on_track
    else
      :behind
    end
  end

  # The single definition of "behind pace" for counts and copy. Paused goals
  # are excluded even when their raw status computes :behind — pausing stops
  # the pace clock on purpose, so surfacing them as behind (or summing them
  # into "needs this month") would nag the user about a goal they shelved.
  #
  # Maintained reserves are excluded for a different reason: they have no
  # pace at all. monthly_target_amount and pace both derive from target_date,
  # which a reserve does not have, so "save X/month to catch up" would be
  # advice about a deadline that does not exist.
  def behind_pace?
    !paused? && !maintained? && status == :behind
  end

  # Date of the most-recently-matched pledge's underlying entry. Used by the
  # show header to display "Last saved N days ago". Anchoring on the entry's
  # date keeps the readout stable under sync re-runs (which would bump
  # pledge#updated_at). Returns nil if no pledge has resolved yet.
  def last_matched_pledge_at
    return @last_matched_pledge_at if defined?(@last_matched_pledge_at)

    @last_matched_pledge_at = Entry
      .where(entryable_type: "Transaction")
      .joins("INNER JOIN goal_pledges ON goal_pledges.matched_transaction_id = entries.entryable_id")
      .where(goal_pledges: { goal_id: id, status: "matched" })
      .maximum(:date)
  end

  def last_matched_pledge_days_ago
    last = last_matched_pledge_at
    return nil if last.nil?

    (Date.current - last).to_i
  end

  # True when any linked account is wired to a live sync provider (Plaid,
  # SimpleFIN, or any AccountProvider. Brex, Enable Banking, IBKR, Kraken,
  # SnapTrade, Lunchflow). Drives the pledge-create copy: connected accounts
  # get the "I just transferred…" path; manual-only accounts get "I just
  # saved…" so users aren't told to wait for a sync that won't happen.
  def any_connected_account?
    linked_accounts.any? { |a| !a.manual? }
  end

  # "I just transferred" when any linked account resolves pledges via a transfer
  # (synced accounts AND investment accounts, per default_pledge_kind); "I just
  # saved" only for manual cash accounts. Keyed off default_pledge_kind so the
  # copy matches the kind actually saved — a manual brokerage uses transfer, not
  # manual_save, so it must not show the "update your manual balance" path.
  def pledge_action_label_key
    pledges_use_transfer? ? "goals.show.pledge_just_transferred" : "goals.show.pledge_just_saved"
  end

  def pledges_use_transfer?
    linked_accounts.any? { |a| a.default_pledge_kind == "transfer" }
  end

  # { account_id => palette_hex } for this goal's linked accounts. Stable
  # within a goal (so the preview-card avatar stack on the index and the
  # funding-widget rows + distribution bar on the show page agree on which
  # color belongs to which account) and collision-free up to PALETTE size
  # (10 colors). Sort by id so the assignment doesn't shuffle when the
  # accounts are re-loaded in a different order.
  def account_color_map
    @account_color_map ||= begin
      palette = Goals::AvatarComponent::PALETTE
      linked_accounts.sort_by(&:id).each_with_index.to_h do |account, i|
        [ account.id, palette[i % palette.size] ]
      end
    end
  end

  # Confirm dialog for deleting this goal, shared by the show-page kebab and
  # the index card kebab so the two can't drift. Spelled out rather than using
  # CustomConfirm.for_resource_deletion, whose generic "This is not reversible"
  # reads scarier than a goal delete is: only the goal, its account links and
  # its pledge history go — the accounts, balances and transactions behind it
  # are untouched.
  def deletion_confirm
    CustomConfirm.new(
      destructive: true,
      high_severity: true,
      title: I18n.t("goals.show.confirm_delete_title"),
      # Escaped: the dialog assigns `body` to innerHTML (so bodies like the
      # accounts' confirm_body_html can carry <p>), so a goal named
      # "<img src=x onerror=…>" would otherwise run when a family member opens
      # the confirmation. Only `body` needs this — the dialog sets its title and
      # button label with textContent.
      body: I18n.t("goals.show.confirm_delete_body", name: ERB::Util.html_escape(name)),
      btn_text: I18n.t("goals.show.confirm_delete_cta")
    )
  end

  # Single-line state summary rendered between the header and the ring on
  # the show page. Replaces the stacked catch-up alert + inline status pill;
  # carries the same actionable copy without owning a CTA. Returns nil when
  # the projection-side cards already convey state (paused / archived /
  # completed / reached) so the callout doesn't double up.
  def status_callout_context
    return nil if paused? || archived? || completed? || status == :reached

    case status
    when :behind
      delta = catch_up_delta_money.amount
      if delta.positive?
        I18n.t("goals.show.status_callout.behind",
               amount: catch_up_delta_money.format(precision: 0))
      else
        I18n.t("goals.show.status_callout.behind_covered")
      end
    when :on_track
      if target_date && pace.to_d.positive?
        months = (remaining_amount.to_d / pace.to_d).ceil
        I18n.t("goals.show.status_callout.on_track",
               date: I18n.l(Date.current >> months.to_i, format: "%b %Y"))
      end
    when :no_target_date
      I18n.t("goals.show.status_callout.no_target_date")
    when :depleted
      # A drained reserve had no callout at all: the one status that most
      # deserves a line of explanation was the one that said nothing.
      I18n.t("goals.show.status_callout.depleted",
             amount: remaining_amount_money.format(precision: 0))
    end
  end

  # Header copy under the goal title on show. Used to live as a multi-line
  # if/elsif block in show.html.erb. Keeps the view template free of date
  # math + i18n key picking.
  # The dot-separated segments of the header line, kept as separate strings so
  # the view can stop a short one breaking mid-phrase. Joined into a single
  # string, "184 days left" could wrap after "days" and orphan "left" on the
  # next line — which is what a phone did.
  def header_summary_parts
    parts = []
    if target_date
      days = (target_date - Date.current).to_i
      past_due = days < 0 && !(completed? || status == :reached)
      if past_due
        parts << I18n.t("goals.show.header.target_by_past",
                        amount: target_amount_money.format(precision: 0),
                        date: I18n.l(target_date, format: :long))
      else
        parts << I18n.t("goals.show.header.target_by",
                        amount: target_amount_money.format(precision: 0),
                        date: I18n.l(target_date, format: :long))
        if days > 0 && !(completed? || status == :reached)
          parts << I18n.t("goals.goal_card.days_left", count: days)
        end
      end
    else
      parts << I18n.t("goals.show.header.target",
                      amount: target_amount_money.format(precision: 0))
    end
    parts
  end

  # Single source of truth for the projection-chart subtitle / chart-aria
  # description. Used to live inline in show.html.erb as a 17-line if/elsif
  # chain. Returns an `html_safe` string when it picks the `_html` variant.
  # The two statuses that mean "this one wants looking at": a goal off its
  # pace, and a reserve below its floor. Named once because three places were
  # spelling the pair out and one of them had already fallen behind.
  def needs_attention?
    status.in?(%i[behind depleted])
  end

  def projection_summary
    return @projection_summary if defined?(@projection_summary)

    @projection_summary =
      if maintained?
        # A reserve holds a level; there is no finish line to project toward
        # and no target to have "hit". It never reaches the projection panel
        # today — the shortfall and celebration panels catch it first — but
        # this method reads as the single source of truth for that subtitle,
        # so it should not hand a caller a one-off's wording.
        I18n.t("goals.show.projection.reserve")
      elsif completed? || progress_percent >= 100
        I18n.t("goals.show.projection.reached")
      elsif target_date.nil?
        I18n.t("goals.show.projection.no_target_date")
      elsif monthly_target_amount && pace.to_d < monthly_target_amount.to_d
        I18n.t("goals.show.projection.behind")
      elsif pace.positive?
        months = (remaining_amount.to_d / pace.to_d).ceil
        I18n.t(
          "goals.show.projection.on_track_html",
          date: I18n.l(Date.current >> months.to_i, format: "%b %Y")
        )
      else
        I18n.t("goals.show.projection.no_pace")
      end
  end

  # Monthly extra needed beyond the current pace + currently-open pledges
  # to hit the target on time. Pending pledges are approximate (one-off
  # amounts treated as this-month inflow) but excluding them produced the
  # bad case where the alert demanded $X/mo while the user had already
  # pledged $X, telling them to act on top of the action they just took.
  # Clamps at zero so a fully-covered goal doesn't surface a $0 demand.
  def catch_up_delta_money
    return Money.new(0, currency) if monthly_target_amount.nil?

    pending = open_pledges.sum(:amount).to_d
    delta = [ monthly_target_amount.to_d - pace.to_d - pending, 0 ].max
    Money.new(delta, currency)
  end

  private
    # This goal's amount from one linked account under the active progress
    # basis: net contributions (market-gain-excluded, floored at 0) on the
    # contributions basis, or the allocation-aware backing balance otherwise.
    def account_amount_for(account)
      base = contributions_basis? ? net_contributed_for(account) : account.balance.to_d
      backing_share_for(account, base)
    end

    # Net contributions into `account` to date = current value minus cumulative
    # market gain/loss (sum of balances.net_market_flows), floored at 0.
    # Depository accounts have zero net_market_flows, so this equals their
    # balance. The per-account base on the contributions basis.
    def net_contributed_for(account)
      market_gain = (market_flows[account.id] || 0).to_d
      [ account.balance.to_d - market_gain, 0.to_d ].max
    end

    # This goal's share of one linked account given a per-account `base` amount
    # (the live balance on the balance basis, net contributions on the
    # contributions basis). Shared-pool semantics are the same either way: the
    # goal's OWN earmark is read from its own goal_accounts (reliable even for
    # an archived goal, which is excluded from the pool); OTHER non-archived
    # goals' fixed earmarks come from the shared pool. A fixed earmark takes its
    # slice; an unallocated link takes the remainder after others' fixed
    # earmarks. When fixed earmarks exceed the base they're scaled down pro-rata
    # (to within sub-cent rounding) so shares never sum past it — no
    # double-counting. A non-positive base backs nothing.
    def backing_share_for(account, base)
      base = base.to_d
      return 0.to_d if base <= 0

      mine = own_allocation_for(account)
      others_fixed = (pooled_allocations[account.id] || [])
        .reject { |r| r[:goal_id] == id }
        .sum { |r| r[:allocated_amount].to_d }

      if mine
        total_fixed = others_fixed + mine
        if total_fixed > base && total_fixed.positive?
          (mine * (base / total_fixed)).round(4) # pro-rata haircut
        else
          mine
        end
      else
        [ base - others_fixed, 0 ].max # unallocated link: the remainder
      end
    end

    # This goal's own earmark on `account` (a BigDecimal, or nil for a
    # whole-balance link). Read from the loaded goal_accounts association so it
    # is correct even for archived goals, which are excluded from the pool.
    def own_allocation_for(account)
      goal_accounts.find { |ga| ga.account_id == account.id }&.allocated_amount
    end

    # Family-wide map of non-archived goal earmarks. Injected once per request
    # by the controller on index (one query for the whole page); falls back to
    # a single query for the standalone (show) case.
    def pooled_allocations
      @pooled_allocations ||= self.class.pooled_allocations_for(family)
    end

    def market_flows
      @market_flows ||= self.class.market_flows_for(family)
    end

    def pooled_pace
      @pooled_pace ||= self.class.pace_for(family)
    end

    def apply_state_change_side_effects
      previous_state, next_state = saved_change_to_state

      # The memos were cleared at transition time, but anything that read the
      # goal between then and the save will have refilled them from the old
      # state. Cleared again so `current_balance` below is the closing figure.
      reset_state_dependent_caches!

      if next_state == "completed"
        # Freeze what the goal actually reached. A completed goal reserves
        # nothing, but its amount would still be recomputed from the live
        # balance — so spending the money would walk the finished goal back
        # down and rewrite its own history.
        update_columns(completed_amount: current_balance, completed_at: Time.current)
      elsif previous_state.in?(RELEASED_STATES) && !next_state.in?(RELEASED_STATES)
        thaw_completed_amount!
      end
    end

    # Claims the outflow for this goal, refusing one already claimed. Inside
    # the caller's transaction, so a refusal here rolls the consumption back
    # rather than leaving the goal credited for a spend it did not record.
    def stamp_consumption!(txn)
      txn.with_lock do
        claimed_by = txn.extra&.dig("goal", "consumed_goal_id")
        if claimed_by.present? && claimed_by != id
          raise ConsumptionRefused.new(:transaction_already_claimed)
        end
        raise ConsumptionRefused.new(:transaction_already_claimed) if claimed_by == id

        extra = txn.extra || {}
        extra["goal"] = (extra["goal"] || {}).merge("consumed_goal_id" => id)
        txn.update!(extra: extra)
      end
    end

    def consumption_link_for(account)
      links = goal_accounts.to_a
      raise ConsumptionRefused.new(:no_linked_account) if links.empty?

      if account.nil?
        raise ConsumptionRefused.new(:account_required) if links.size > 1
        return links.first
      end

      links.find { |link| link.account_id == account.id } ||
        raise(ConsumptionRefused.new(:account_not_linked))
    end

    # Reopening or unarchiving hands the goal back to the live calculation: it
    # is being funded again, so a figure frozen at an earlier close would
    # misreport it from here on. Reopening restarts the goal, so what was spent
    # under its previous life goes with the frozen figure — leaving it would
    # have the reopened goal claim credit for money spent on something it has
    # already been closed for.
    def thaw_completed_amount!
      attrs = { completed_amount: nil, completed_at: nil }

      # Only a goal that actually closed a lifecycle starts over. A goal
      # archived straight from active never froze a figure, so unarchiving it
      # is picking the same goal back up rather than restarting it — wiping
      # what it had recorded as spent would delete history nothing replaced,
      # and drop its progress for no reason the user can see.
      attrs[:consumed_amount] = 0 if completed_amount.present?

      update_columns(**attrs)
    end

    # Leaves whatever the user typed when the median cannot be computed: the
    # presence + positivity validations still apply, so a family with no
    # spending history is asked for a figure rather than blocked.
    #
    # Runs on a target_amount edit too, and overwrites it. In this mode the
    # floor is derived, not typed — the form disables the field, but the
    # invariant cannot depend on the form: a goal left saying
    # "six months of expenses" while holding a figure someone typed is
    # untrue on its face, and would stay untrue until the next monthly run.
    def apply_months_of_expenses_target
      computed = months_of_expenses_amount
      return self.target_amount = computed if computed

      # Nothing to derive from and a typed figure on its way in: keep the one
      # the reserve already had. Same reasoning as the refresh job — a stale
      # floor beats a wrong one, and this one would be wearing a label saying
      # it was computed.
      self.target_amount = target_amount_in_database if target_amount_changed? && !new_record?
    end

    # target_months only means something for a reserve on the months basis.
    # Allowing it elsewhere would leave a number nothing reads, which the
    # refresh job would then look at and skip for reasons no one could see.
    def months_target_requires_a_reserve
      return if target_mode == "fixed" && target_months.blank?
      return if months_of_expenses_target? && maintained? && target_months.present?

      if months_of_expenses_target? && !maintained?
        errors.add(:target_mode, :months_requires_maintained)
      elsif months_of_expenses_target?
        errors.add(:target_months, :blank)
      else
        errors.add(:target_months, :only_with_months_mode)
      end
    end

    # Cleared after every AASM transition. The state column drives the
    # display_status / projection_summary memos; without this the same instance
    # keeps returning the pre-transition value if a controller calls archive! /
    # pause! and then renders without reload.
    def reset_state_dependent_caches!
      # current_balance depends on the goal's own state — a goal in any of
      # RELEASED_STATES is excluded from the shared pool, and a completed one
      # reads its frozen amount instead of its accounts — so the
      # balance-derived memos must be cleared on a transition too, not just
      # the status memos.
      %i[
        @display_status @projection_summary
        @current_balance @current_balance_money
        @remaining_amount @remaining_amount_money
        @progress_percent @monthly_target_amount
        @progress_amount_money @consumed_amount_money
        @pace @pace_money @status @pooled_allocations
      ].each do |ivar|
        remove_instance_variable(ivar) if instance_variable_defined?(ivar)
      end
    end

    # K/M shorthand for narrow chart annotations (axis ticks, projection
    # short-form, pending-pledge badge). Locale-aware currency symbol via
    # Money so the chart matches the rest of the app for EUR/GBP families.
    def short_money(amount, code)
      amount_f = amount.to_f
      symbol = Money.new(0, code).currency.symbol
      abs = amount_f.abs
      if abs >= 1_000_000
        short = (amount_f / 1_000_000.0).round(1)
        "#{symbol}#{short == short.to_i ? short.to_i : short}M"
      elsif abs >= 1_000
        short = (amount_f / 1_000.0).round(1)
        "#{symbol}#{short == short.to_i ? short.to_i : short}K"
      else
        "#{symbol}#{amount_f.round.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse}"
      end
    end

    def balance_series_values
      return [] if linked_accounts.empty?

      Balance::ChartSeriesBuilder.new(
        account_ids: linked_accounts.map(&:id),
        currency: currency,
        period: Period.last_90_days
      ).balance_series.values
    rescue StandardError => e
      # Degrade gracefully (chart drops to target-line-only) but surface
      # the failure; silent fallbacks here masked real Builder bugs.
      Rails.logger.error("Goal##{id} balance series failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      []
    end

    def must_have_at_least_one_linked_account
      return unless goal_accounts.reject(&:marked_for_destruction?).empty?

      errors.add(:base, :at_least_one_linked_account_required)
    end

    def linked_accounts_must_be_fundable
      offending = goal_accounts.reject(&:marked_for_destruction?).reject do |sga|
        sga.account&.depository? || sga.account&.investment?
      end
      return if offending.empty?

      errors.add(:linked_accounts, :must_be_fundable)
    end

    # Goals funded by an investment account default to the contributions basis
    # (so a market swing doesn't move them); depository-only goals stay on the
    # balance basis. Only auto-set when the basis is still the default.
    def default_progress_basis_for_investment
      return unless goal_accounts.any? { |ga| ga.account&.investment? }
      return unless progress_basis.blank? || progress_basis == "balance"

      self.progress_basis = "contributions"
    end

    def linked_accounts_must_match_goal_currency
      return if currency.blank?

      mismatched = goal_accounts.reject(&:marked_for_destruction?).reject do |sga|
        sga.account.nil? || sga.account.currency == currency
      end
      return if mismatched.empty?

      errors.add(:linked_accounts, :currency_mismatch)
    end

    def linked_accounts_must_belong_to_family
      return if family.nil?

      foreign = goal_accounts.reject(&:marked_for_destruction?).reject do |sga|
        sga.account.nil? || sga.account.family_id == family_id
      end
      return if foreign.empty?

      errors.add(:linked_accounts, :must_belong_to_family)
    end

    # Switching a released goal to `maintained` would leave a reserve sitting in
    # `completed` — a state that has HANDED BACK its earmark — while the show
    # page promises its money stays reserved. The conversion has to go through
    # an active state, where `complete` is already refused for a reserve.
    # A reserve refuses consumption, so letting a goal that has already recorded
    # some become one leaves that figure stranded: it still counts toward
    # progress, on an object whose whole model says spending is a shortfall to
    # refill rather than a job done. The two readings cannot both be true.
    def kind_locked_once_consumed
      return unless will_save_change_to_kind?
      return unless maintained?
      return unless consumed_amount.to_d.positive?

      errors.add(:kind, :locked_once_consumed)
    end

    # The consumed total is checked while consuming, which left the ordinary
    # edit form free to lower the target underneath it — a goal reporting more
    # spent than it ever set out to save.
    def target_must_cover_what_was_consumed
      return unless target_amount.present? && consumed_amount.to_d.positive?
      return if target_amount.to_d >= consumed_amount.to_d

      errors.add(:target_amount, :below_consumed)
    end

    def kind_locked_while_released
      return unless persisted? && will_save_change_to_kind?
      # The PERSISTED state, not the one in memory. A single update can set
      # `state: "active"` alongside the new kind, and reading the attribute
      # would see the goal as already reopened and wave it through — while the
      # direct write skipped the `reopen` transition that clears
      # `completed_amount`, leaving an active reserve reporting a frozen
      # snapshot forever. Reopening has to be its own gesture.
      return unless state_in_database.in?(RELEASED_STATES)

      errors.add(:kind, :locked_while_released)
    end

    def clear_target_date_for_maintained
      self.target_date = nil if maintained?
    end

    def currency_locked_once_linked
      return unless persisted? && currency_changed?
      return unless goal_accounts.where.not(id: nil).exists?

      errors.add(:currency, :locked_after_linked)
    end

    # Archiving a goal frees the accounts it claimed in full, so another goal
    # can legitimately claim one of them while it is away. Restoring it would
    # then put two whole-account links back on the same account and reopen the
    # double-counting `GoalAccount#whole_account_link_must_be_exclusive` closes
    # — that check only fires when a link is written, and a state change writes
    # none.
    #
    # A validation rather than an AASM guard: `may_fire_event?` stays true, the
    # save fails, and GoalsController#perform_transition! already surfaces
    # `errors.full_messages`. The user reads which goal holds the account
    # instead of a generic "can't do that in this state".
    def restore_must_not_recreate_whole_account_conflict
      return unless will_save_change_to_state?

      previous_state, next_state = state_change_to_be_saved
      return unless previous_state.in?(RELEASED_STATES)
      return if next_state.in?(RELEASED_STATES)

      conflict = whole_account_conflicts_on(own_whole_account_ids).first
      return if conflict.nil?

      errors.add(
        :base,
        :whole_account_conflict_on_restore,
        goal_name: conflict.goal.name,
        account_name: conflict.account.name
      )
    end

    # Accounts this goal claims in full. Read from the loaded association so it
    # is correct for a goal whose links were built but not yet saved.
    def lock_whole_account_claims_in_order
      ids = own_whole_account_ids
      ids |= goal_accounts.filter_map { |ga| ga.account_id if ga.will_save_change_to_allocated_amount? }
      ids.compact.uniq.sort.each { |account_id| self.class.lock_whole_account_claims!(account_id) }
    end

    def own_whole_account_ids
      goal_accounts
        .reject(&:marked_for_destruction?)
        .select(&:whole_account?)
        .filter_map(&:account_id)
    end
end
