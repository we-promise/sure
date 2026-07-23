# A proactive, typed observation about a family's finances, produced nightly
# by GenerateInsightsJob. The financial logic lives in Insight::Generators::*;
# the LLM (when configured) only writes the `body` prose from pre-computed
# numbers, so rows are safe to render verbatim.
#
# Prose semantics: rows carrying a `template_key` render their title and
# template body live from i18n in the viewer's locale — translations added or
# fixed after generation apply retroactively, and a family locale switch takes
# effect immediately. `body` is only stored when an LLM wrote it (prose can't
# be re-rendered); rows predating `template_key` fall back to the title/body
# snapshotted at generation time until the job refreshes them.
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
  validates :title, :dedup_key, presence: true
  # Mirrors the DB unique index so direct callers get a validation error
  # instead of ActiveRecord::RecordNotUnique; races still hit the index.
  validates :dedup_key, uniqueness: { scope: :family_id }

  # Everything the user hasn't dismissed; what the feed renders.
  scope :visible, -> { where(status: [ :active, :read ]) }
  scope :ordered, -> {
    order(Arel.sql("CASE insights.priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END"))
      .order(generated_at: :desc)
  }

  ISO_DATE_FACT = /\A\d{4}-\d{2}-\d{2}\z/

  class << self
    # Facts are stored as raw values (floats, ISO date strings, money facts)
    # and localized at interpolation time, both here for live-rendered
    # templates and by Insight::BodyWriter before handing them to the LLM.
    def localize_facts(facts)
      (facts || {}).to_h { |key, value| [ key.to_sym, localize_fact_value(value) ] }
    end

    # Floats get the locale's decimal separator and a true minus sign (U+2212 —
    # the app types negatives with a minus, not a hyphen); ISO dates localize;
    # money facts (built via Insight::Generator#money_fact) format in their
    # own currency; everything else (names, integer counts) passes through.
    # Integers stay raw so i18n pluralization keeps working on `count` facts.
    def localize_fact_value(value)
      case value
      when Float
        formatted = ActiveSupport::NumberHelper.number_to_rounded(value.abs, precision: 1, strip_insignificant_zeros: true)
        value.negative? ? "−#{formatted}" : formatted
      when ISO_DATE_FACT
        I18n.l(Date.iso8601(value))
      when Hash
        money_fact?(value) ? format_money_fact(value) : value
      else
        value
      end
    end

    private
      def money_fact?(value)
        value = value.with_indifferent_access
        value[:amount].present? && value[:currency].present?
      end

      def format_money_fact(value)
        value = value.with_indifferent_access
        options = value[:precision].present? ? { precision: value[:precision].to_i } : {}
        Money.new(value[:amount], value[:currency]).format(**options)
      end
  end

  def display_title
    return title if template_key.blank?

    I18n.t("insights.titles.#{title_i18n_key}", **localized_facts, default: title)
  end

  def display_body
    return body if body.present?
    return "" if template_key.blank?

    # body is always nil here (the presence check above already returned),
    # so default: body would be default: nil — i18n treats Array(nil) as no
    # default at all and raises/renders "translation missing" instead of
    # falling back gracefully, unlike display_title's default: title.
    I18n.t("insights.templates.#{template_key}", **localized_facts, default: "")
  end

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

  private
    # Titles share the template's variant except where the title copy doesn't
    # split the same way: a negative savings rate is still just a drop, and
    # budget_at_risk titles pluralize on the flagged-category count instead of
    # splitting over/near.
    def title_i18n_key
      case template_key
      when "savings_rate_change.down_negative" then "savings_rate_change.down"
      when "budget_at_risk.over", "budget_at_risk.near" then "budget_at_risk"
      else template_key
      end
    end

    def localized_facts
      args = self.class.localize_facts(facts)
      # The stored month name is frozen in the generation locale; the period
      # start carries the same information locale-free, so re-derive it.
      args[:month] = I18n.l(period_start, format: "%B") if args.key?(:month) && period_start
      args
    end
end
