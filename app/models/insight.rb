class Insight < ApplicationRecord
  belongs_to :family

  INSIGHT_TYPES = %w[
    spending_anomaly
    cash_flow_warning
    net_worth_milestone
    subscription_audit
    savings_rate_change
    idle_cash
    budget_on_track
    budget_at_risk
  ].freeze

  PRIORITIES = %w[high medium low].freeze
  STATUSES   = %w[active read dismissed].freeze

  enum :insight_type, INSIGHT_TYPES.index_by(&:itself), validate: true
  enum :priority,     PRIORITIES.index_by(&:itself),    validate: true
  enum :status,       STATUSES.index_by(&:itself),      validate: true

  validates :title, :body, :dedup_key, presence: true
  validates :insight_type, :priority, :status, presence: true

  scope :visible,       -> { where(status: %w[active read]) }
  scope :for_dashboard, -> { visible.ordered.limit(3) }
  scope :recent,        -> { where(generated_at: 30.days.ago..) }
  scope :ordered,       -> {
    order(
      Arel.sql("CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 WHEN 'low' THEN 2 END ASC, generated_at DESC")
    )
  }

  def mark_read!
    update!(status: :read, read_at: Time.current) if active?
  end

  def dismiss!
    update!(status: :dismissed, dismissed_at: Time.current)
  end
end
