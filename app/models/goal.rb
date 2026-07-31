class Goal < ApplicationRecord
  include AASM, Monetizable

  COLORS = Category::COLORS
  ICONS = Category.icon_codes

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

  validate :must_have_at_least_one_linked_account
  validate :linked_accounts_must_be_fundable
  validate :linked_accounts_must_match_goal_currency
  validate :linked_accounts_must_belong_to_family
  validate :currency_locked_once_linked

  monetize :target_amount

  scope :alphabetically, -> { order(Arel.sql("LOWER(name) ASC")) }
  scope :active_first, lambda {
    order(Arel.sql("CASE state WHEN 'active' THEN 0 WHEN 'paused' THEN 1 WHEN 'completed' THEN 2 ELSE 3 END"))
  }

  def self.advisory_lock_key_for(family_id)
    Digest::SHA1.hexdigest("goals:family:#{family_id}").to_i(16) % (2**63)
  end

  # Family-wide map of non-archived goal earmarks, grouped by account_id:
  # { account_id => [{ goal_id:, allocated_amount: }, ...] }. The controller
  # assigns this to each goal on index (goal.pooled_allocations = ...) so the
  # shared-pool backing math runs ONE query for the whole page instead of one
  # per goal.
  def self.pooled_allocations_for(family)
    GoalAccount.joins(:goal)
               .where(goals: { family_id: family.id })
               .where.not(goals: { state: "archived" })
               .pluck(:account_id, :goal_id, :allocated_amount)
               .group_by(&:first)
               .transform_values do |triples|
                 triples.map { |(_, goal_id, amount)| { goal_id: goal_id, allocated_amount: amount } }
               end
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

    event :complete do
      transitions from: [ :active, :paused ], to: :completed
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
  def account_backing(account)
    Money.new(account_amount_for(account), currency)
  end

  def contributions_basis?
    progress_basis == "contributions"
  end

  # Market value of the goal's backing (balance basis), regardless of the
  # progress basis — the "what it's worth today" figure shown next to
  # contributions on an investment-backed goal.
  def market_value_money
    amount = linked_accounts.select { |a| a.currency == currency }.sum { |a| backing_share_for(a, a.balance.to_d) }
    Money.new(amount, currency)
  end

  def remaining_amount
    @remaining_amount ||= [ target_amount - current_balance, 0 ].max
  end

  def remaining_amount_money
    @remaining_amount_money ||= Money.new(remaining_amount, currency)
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
      ((current_balance.to_d / target_amount.to_d) * 100).floor.clamp(0, 99)
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
      account_ids = linked_accounts.map(&:id)
      net = Entry
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(account_id: account_ids, date: 90.days.ago.to_date..Date.current)
        .where(excluded: false)
        .merge(Transaction.excluding_pending)
        .sum(:amount)
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
    backing_ratio = whole_total.positive? ? (current_balance.to_d / whole_total) : 0.to_d
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
    end
  end

  # Header copy under the goal title on show. Used to live as a multi-line
  # if/elsif block in show.html.erb. Keeps the view template free of date
  # math + i18n key picking.
  def header_summary
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
    parts.join(" · ")
  end

  # Single source of truth for the projection-chart subtitle / chart-aria
  # description. Used to live inline in show.html.erb as a 17-line if/elsif
  # chain. Returns an `html_safe` string when it picks the `_html` variant.
  def projection_summary
    return @projection_summary if defined?(@projection_summary)

    @projection_summary =
      if completed? || progress_percent >= 100
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

    # Cleared after every AASM transition. The state column drives the
    # display_status / projection_summary memos; without this the same
    # instance keeps returning the pre-transition value if a controller
    # calls archive! / pause! and then renders without reload.
    def reset_state_dependent_caches!
      # current_balance now depends on the goal's own archived state (an
      # archived goal is excluded from the shared pool), so the balance-derived
      # memos must be cleared on a transition too, not just the status memos.
      %i[
        @display_status @projection_summary
        @current_balance @current_balance_money
        @remaining_amount @remaining_amount_money
        @progress_percent @monthly_target_amount
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

    def currency_locked_once_linked
      return unless persisted? && currency_changed?
      return unless goal_accounts.where.not(id: nil).exists?

      errors.add(:currency, :locked_after_linked)
    end
end
