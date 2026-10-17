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
    maintained_goal_depleted
    balance_discrepancy
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
  scope :visible, -> { where(status: [ :active, :read ]).about_shared_accounts }

  # The feed is shared by the whole family, so an insight that names an
  # account (metadata account_id) shows only while every active member can
  # see that account. Generators already skip other accounts; this read-time
  # check also covers rows written before access changed (a share revoked, a
  # member joined, the account moved, hidden or deleted), which would
  # otherwise stay in the feed until the next nightly run expires them.
  # Nothing is written, so the row reappears as it was if access is restored.
  #
  # The id is cast to uuid (not the column to text) so the lookup stays a
  # primary-key probe; the CASE keeps a malformed value from raising.
  scope :about_shared_accounts, -> {
    shared_account = Account.visible.accessible_by_all_active_members
      .where("accounts.family_id = insights.family_id")
      .where(<<~SQL.squish)
        accounts.id = CASE
          WHEN insights.metadata->>'account_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          THEN (insights.metadata->>'account_id')::uuid
        END
      SQL
    where("NOT (insights.metadata ? 'account_id')").or(where(shared_account.arel.exists))
  }

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
