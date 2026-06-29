class Goal < ApplicationRecord
  include AASM, Monetizable

  self.inheritance_column = :type

  COLORS = Category::COLORS
  ICONS = Category.icon_codes

  validates :icon, inclusion: { in: ICONS, allow_nil: true }
  validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }, allow_nil: true

  belongs_to :family
  has_many :goal_accounts, dependent: :destroy
  has_many :linked_accounts, through: :goal_accounts, source: :account
  has_many :goal_pledges, dependent: :destroy
  has_many :open_pledges,
           -> { where(status: "open").where("expires_at >= ?", Time.current) },
           class_name: "GoalPledge"

  validates :name, presence: true, length: { maximum: 255 }
  validates :target_amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validate :must_have_at_least_one_linked_account
  validate :linked_accounts_must_be_depository
  validate :linked_accounts_must_match_goal_currency
  validate :linked_accounts_must_belong_to_family
  validate :currency_locked_once_linked

  monetize :target_amount

  scope :alphabetically, -> { order(Arel.sql("LOWER(name) ASC")) }
  scope :active_first, lambda {
    order(Arel.sql("CASE state WHEN 'active' THEN 0 WHEN 'paused' THEN 1 WHEN 'completed' THEN 2 ELSE 3 END"))
  }
  # Savings goals only — the base Goal type. STI subtypes such as
  # Goal::Retirement have their own surfaces (RetirementController) and
  # must NOT be reachable through the shared goal/pledge routes, where
  # any preview-enabled family member could otherwise view, edit, or
  # delete another member's owner-scoped retirement plan.
  scope :savings, -> { where(type: "Goal") }

  def self.advisory_lock_key_for(family_id)
    Digest::SHA1.hexdigest("goals:family:#{family_id}").to_i(16) % (2**63)
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

    event :complete do
      transitions from: [ :active, :paused ], to: :completed
    end

    event :archive do
      transitions from: [ :active, :paused, :completed ], to: :archived
    end

    event :unarchive do
      transitions from: :archived, to: :active
    end
  end

  # Balance is the live balance of every linked depository account that
  # matches the goal's currency. The model validates this invariant at
  # write time, but defensive filter + telemetry here guards against any
  # drift caused by direct DB writes, account-currency edits outside
  # goal validation, or future code that bypasses the validation chain.
  # v1.1+: minus other goals' allocations via the upcoming GoalBacking
  # query.
  def current_balance
    @current_balance ||= begin
      matching = linked_accounts.select { |a| a.currency == currency }
      if matching.size != linked_accounts.size
        Rails.logger.warn("Goal##{id} linked-account currency drift: #{linked_accounts.size - matching.size} of #{linked_accounts.size} mismatched (expected #{currency})")
        Sentry.capture_message("Goal linked-account currency drift", level: :warning, extra: { goal_id: id, expected_currency: currency }) if defined?(Sentry)
      end
      matching.sum { |a| a.balance.to_d }
    end
  end

  def current_balance_money
    @current_balance_money ||= Money.new(current_balance, currency)
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
    saved_series = series_values.map { |v| { date: v.date.to_s, value: v.value.amount.to_f } }

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

  # "I just transferred" for bank-connected accounts, "I just saved" for manual-only.
  def pledge_action_label_key
    any_connected_account? ? "goals.show.pledge_just_transferred" : "goals.show.pledge_just_saved"
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

  # Family-scoped default for base Goal records. Subclasses like
  # Goal::Retirement narrow this to owner-only by overriding.
  def editable_by?(user)
    return false if user.nil?
    family_id == user.family_id
  end

  private
    # Cleared after every AASM transition. The state column drives the
    # display_status / projection_summary memos; without this the same
    # instance keeps returning the pre-transition value if a controller
    # calls archive! / pause! and then renders without reload.
    def reset_state_dependent_caches!
      %i[@display_status @projection_summary].each do |ivar|
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

    def linked_accounts_must_be_depository
      offending = goal_accounts.reject(&:marked_for_destruction?).reject do |sga|
        sga.account&.depository?
      end
      return if offending.empty?

      errors.add(:linked_accounts, :must_be_depository)
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
