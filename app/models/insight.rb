# A proactive, typed observation about a family's finances, produced nightly
# by GenerateInsightsJob. The financial logic lives in Insight::Generators::*;
# the LLM (when configured) only writes the `body` prose from pre-computed
# numbers, so rows are safe to render verbatim.
#
# Status semantics: `read` and `acknowledged` are user actions; `expired` is the
# system's — set when a signal stops being generated (the condition cleared).
#
# "Acknowledged" rather than "dismissed" because that is what the state has
# always actually meant. GenerateInsightsJob resurfaces a row whose bucketed
# metadata changes materially even if the user acknowledged the stale version,
# and 6 of 8 generators scope `dedup_key` to a month, so acknowledging July's
# budget card says nothing about August's. The contract is: acknowledgement
# covers the numbers you saw; new numbers are a new insight. The DB value stays
# `"dismissed"` (and the `dismissed_at` column keeps its name) so this needed no
# migration — only the vocabulary the code and the UI speak was wrong.
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

  # How many the dashboard widget shows. Shared so PagesController (first render)
  # and InsightsController (re-render after acknowledging) can't drift apart.
  FEED_LIMIT = 3

  enum :status, { active: "active", read: "read", acknowledged: "dismissed", expired: "expired" }
  enum :priority, { high: "high", medium: "medium", low: "low" }, prefix: true

  validates :insight_type, presence: true, inclusion: { in: TYPES }
  validates :title, :body, :dedup_key, presence: true
  # Mirrors the DB unique index so direct callers get a validation error
  # instead of ActiveRecord::RecordNotUnique; races still hit the index.
  validates :dedup_key, uniqueness: { scope: :family_id }

  # Everything the user hasn't acknowledged; what the feed renders.
  scope :visible, -> { where(status: [ :active, :read ]) }
  scope :ordered, -> {
    order(Arel.sql("CASE insights.priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END"))
      .order(generated_at: :desc)
  }

  def mark_read!
    return unless active?

    update!(status: :read, read_at: Time.current)
  end

  def acknowledge!
    update!(status: :acknowledged, dismissed_at: Time.current)
  end

  # Undoes an acknowledgement without re-badging the insight as new — the user
  # has obviously seen it, so it returns as read. Guarded to only reverse an
  # actual acknowledgement: a stale/replayed undo (e.g. an old toast link
  # clicked after GenerateInsightsJob has since expired or resurrected this
  # insight) would otherwise force it back to :read from whatever state it's
  # really in, including bringing an :expired insight back into view.
  def unacknowledge!
    return unless acknowledged?

    update!(status: :read, dismissed_at: nil, read_at: read_at || Time.current)
  end
end
