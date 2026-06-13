class Insight < ApplicationRecord
  belongs_to :family

  TYPES = %w[
    spending_anomaly
    cash_flow_warning
    net_worth_milestone
    subscription_audit
    savings_rate_change
    idle_cash
    budget_at_risk
    budget_on_track
  ].freeze

  enum :priority, { high: "high", medium: "medium", low: "low" }, prefix: true
  enum :status, { active: "active", read: "read", dismissed: "dismissed" }, prefix: true

  validates :insight_type, presence: true, inclusion: { in: TYPES }
  validates :title, :body, :dedup_key, :currency, presence: true
  validates :dedup_key, uniqueness: { scope: [ :family_id, :insight_type ] }

  scope :visible, -> { where(status: %w[active read]) }
  scope :chronological, -> { order(generated_at: :desc) }
  scope :by_priority, -> { order(Arel.sql("CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END"), generated_at: :desc) }

  def mark_read!
    return if status_read? || status_dismissed?

    update!(status: "read", read_at: Time.current)
  end

  def dismiss!
    update!(status: "dismissed", dismissed_at: Time.current)
  end
end
