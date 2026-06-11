class GoalPledge < ApplicationRecord
  include Monetizable

  KINDS = %w[transfer manual_save].freeze
  STATUSES = %w[open matched cancelled expired].freeze

  DEFAULT_WINDOW_DAYS = 7
  EXTEND_DAYS = 7
  MATCH_DATE_TOLERANCE_DAYS = 5
  MATCH_AMOUNT_TOLERANCE_ABSOLUTE = BigDecimal("0.50")
  MATCH_AMOUNT_TOLERANCE_RATIO = BigDecimal("0.01")

  belongs_to :goal
  belongs_to :account
  belongs_to :matched_transaction, class_name: "Transaction", optional: true

  enum :kind, KINDS.index_by(&:itself), prefix: :kind
  enum :status, STATUSES.index_by(&:itself), prefix: :status

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validates :expires_at, presence: true
  validate :account_must_be_linked_to_goal
  validate :currency_matches_goal
  validate :no_duplicate_open_pledge, on: :create

  monetize :amount

  # Newest first. Used by the show page to render pending-pledge banners in
  # "most-recent on top" order. Not actually chronological; kept for clarity.
  scope :reverse_chronological, -> { order(created_at: :desc) }
  scope :open_and_expired_now, -> {
    where(status: "open").where("expires_at < ?", Time.current)
  }

  before_validation :assign_defaults, on: :create
  before_destroy :clear_matched_transaction_extra

  # Tolerance check: entry date within [created_at − 5d, expires_at] (so
  # extend! widens the upper bound) and amount within ±$0.50 OR ±1%.
  #
  # The amount being compared is the money that actually moved IN:
  #   - transfer pledges resolve against a Transaction inflow (Sure
  #     convention: inflow < 0), so the entry amount IS the contribution.
  #   - manual_save pledges resolve against a Valuation, whose amount is the
  #     account's full new TOTAL balance — not the contribution. The caller
  #     (Account::ReconciliationManager) passes the balance delta
  #     (new_balance − prior_balance) via `valuation_delta`; that delta is
  #     the contribution we match against. Comparing the raw valuation amount
  #     would only ever match on an account whose entire balance equals the
  #     pledge (i.e. one starting from ~$0).
  #
  # Both kinds only fire on money coming in: transfers require an inflow
  # entry, manual_save requires a positive balance delta. Without these
  # guards, .abs below would let a $200 outflow / a $200 drawdown satisfy a
  # $200 pledge as readily as a $200 deposit.
  def matches?(entry, valuation_delta: nil)
    return false unless status_open?
    return false unless entry.account_id == account_id

    is_valuation = entry.entryable.is_a?(Valuation)

    if is_valuation
      return false if valuation_delta.nil? || valuation_delta.to_d <= 0
    elsif kind_transfer? && !entry.amount.to_d.negative?
      return false
    end

    earliest = created_at.to_date - MATCH_DATE_TOLERANCE_DAYS.days
    latest = [ created_at.to_date + MATCH_DATE_TOLERANCE_DAYS.days, expires_at.to_date ].max
    return false unless entry.date >= earliest && entry.date <= latest

    txn_amount = (is_valuation ? valuation_delta.to_d : entry.amount.to_d).abs
    pledge_amount = amount.to_d
    diff_abs = (txn_amount - pledge_amount).abs

    return true if diff_abs <= MATCH_AMOUNT_TOLERANCE_ABSOLUTE
    return true if pledge_amount.positive? && (diff_abs / pledge_amount) <= MATCH_AMOUNT_TOLERANCE_RATIO

    false
  end

  def resolve_with!(transaction)
    with_lock do
      raise NotOpenError, "Pledge no longer open" unless status_open?

      transaction.with_lock do
        pledge_id_in_extra = transaction.extra.dig("goal", "pledge_id")
        if pledge_id_in_extra.present? && pledge_id_in_extra != id
          raise AlreadyClaimedError, "Transaction ##{transaction.id} already claimed by pledge ##{pledge_id_in_extra}"
        end

        extra = transaction.extra || {}
        extra["goal"] = (extra["goal"] || {}).merge("pledge_id" => id)
        transaction.update!(extra: extra)

        update!(status: "matched", matched_transaction_id: transaction.id)
      end
    end
  end

  # Valuation-backed match: no transaction to stamp, just flip the pledge.
  def resolve_with_valuation!
    with_lock do
      raise NotOpenError, "Pledge no longer open" unless status_open?

      update!(status: "matched")
    end
  end

  class NotOpenError < StandardError; end
  # Raised when a Transaction is already claimed by a different open
  # pledge. Lets the reconciler distinguish a known race ("another worker
  # got there first") from a generic validation failure.
  class AlreadyClaimedError < StandardError; end

  def extend!(days: EXTEND_DAYS)
    raise NotOpenError, "Only open pledges can be extended" unless status_open?

    update!(expires_at: expires_at + days.days)
  end

  def cancel!
    raise NotOpenError, "Only open pledges can be cancelled" unless status_open?

    update!(status: "cancelled")
  end

  def expire!
    return unless status_open?

    update!(status: "expired")
  end

  def days_left
    return 0 unless status_open?

    delta = ((expires_at - Time.current) / 1.day).ceil
    [ delta, 0 ].max
  end

  private
    def assign_defaults
      self.kind ||= "transfer"
      self.status ||= "open"
      self.expires_at ||= Time.current + DEFAULT_WINDOW_DAYS.days
      self.currency ||= goal&.currency
    end

    def account_must_be_linked_to_goal
      return if goal.nil? || account.nil?
      return if goal.goal_accounts.where(account_id: account_id).exists?

      errors.add(:account, :must_be_linked_to_goal)
    end

    def currency_matches_goal
      return if goal.nil? || currency.blank?
      return if currency == goal.currency

      errors.add(:currency, :must_match_goal)
    end

    # Guards against a double-click that creates two identical open pledges,
    # which would render two yellow banners and leave one orphaned to expiry.
    def no_duplicate_open_pledge
      return unless goal_id && account_id && amount && status_open?

      exists = GoalPledge
        .where(goal_id: goal_id, account_id: account_id, amount: amount, status: "open")
        .where("expires_at >= ?", Time.current)
        .exists?

      errors.add(:base, :duplicate_open_pledge) if exists
    end

    def clear_matched_transaction_extra
      return if matched_transaction_id.blank?

      txn = Transaction.find_by(id: matched_transaction_id)
      return if txn.nil?
      return unless txn.extra.dig("goal", "pledge_id") == id

      new_extra = txn.extra.deep_dup
      new_extra["goal"]&.delete("pledge_id")
      new_extra.delete("goal") if new_extra["goal"]&.empty?
      txn.update!(extra: new_extra)
    end
end
