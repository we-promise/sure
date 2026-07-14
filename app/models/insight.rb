# A proactive, typed observation about a family's finances, produced nightly
# by GenerateInsightsJob. The financial logic lives in Insight::Generators::*;
# the LLM (when configured) only writes the `body` prose from pre-computed
# numbers, so rows are safe to render verbatim.
#
# Status semantics: `read` and `dismissed` are user actions; `expired` is the
# system's — set when a signal stops being generated (the condition cleared).
# A returning condition reactivates an expired row but never a dismissed one.
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

  enum :status, { active: "active", read: "read", dismissed: "dismissed", expired: "expired" }
  enum :priority, { high: "high", medium: "medium", low: "low" }, prefix: true

  validates :insight_type, presence: true, inclusion: { in: TYPES }
  validates :title, :body, :dedup_key, presence: true
  # Mirrors the DB unique index so direct callers get a validation error
  # instead of ActiveRecord::RecordNotUnique; races still hit the index.
  validates :dedup_key, uniqueness: { scope: :family_id }

  # Everything the user hasn't dismissed; what the feed renders.
  scope :visible, -> { where(status: [ :active, :read ]) }
  scope :ordered, -> {
    order(Arel.sql("CASE insights.priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END"))
      .order(generated_at: :desc)
  }

  def mark_read!
    return unless active?

    update!(status: :read, read_at: Time.current)
  end

  def dismiss!
    update!(status: :dismissed, dismissed_at: Time.current)
  end

  # Undoes a dismissal without re-badging the insight as new — the user has
  # obviously seen it, so it returns as read.
  def undismiss!
    update!(status: :read, dismissed_at: nil, read_at: read_at || Time.current)
  end
end
