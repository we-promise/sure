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

  monetize :amount

  scope :chronological, -> { order(created_at: :desc) }
  scope :open_and_expired_now, -> {
    where(status: "open").where("expires_at < ?", Time.current)
  }

  before_validation :assign_defaults, on: :create

  # Tolerance check: ±5 days from pledge date, amount within ±$0.50 OR ±1%.
  def matches?(entry)
    return false unless status_open?
    return false unless entry.account_id == account_id

    date_diff = (entry.date - created_at.to_date).abs.to_i
    return false if date_diff > MATCH_DATE_TOLERANCE_DAYS

    txn_amount = entry.amount.to_d.abs
    pledge_amount = amount.to_d
    diff_abs = (txn_amount - pledge_amount).abs

    return true if diff_abs <= MATCH_AMOUNT_TOLERANCE_ABSOLUTE
    return true if pledge_amount.positive? && (diff_abs / pledge_amount) <= MATCH_AMOUNT_TOLERANCE_RATIO

    false
  end

  def resolve_with!(transaction)
    transaction.with_lock do
      pledge_id_in_extra = transaction.extra.dig("goal", "pledge_id")
      raise ActiveRecord::RecordInvalid if pledge_id_in_extra.present? && pledge_id_in_extra != id

      extra = transaction.extra || {}
      extra["goal"] = (extra["goal"] || {}).merge("pledge_id" => id)
      transaction.update!(extra: extra)

      update!(status: "matched", matched_transaction_id: transaction.id)
    end
  end

  def extend!(days: EXTEND_DAYS)
    raise ActiveRecord::RecordInvalid, "Only open pledges can be extended" unless status_open?

    update!(expires_at: expires_at + days.days)
  end

  def cancel!
    raise ActiveRecord::RecordInvalid, "Only open pledges can be cancelled" unless status_open?

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
end
