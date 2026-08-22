# Titles and bodies are persisted as finished prose at generation time (often
# English, or LLM-written English). Re-interpolate the i18n templates only
# when the viewer's locale differs from generation, so a locale switch does
# not wait for a nightly rewrite and AI narration stays visible otherwise.
class Insight::Copy
  DATE_FACT_KEYS = %i[projected_low_date expected_on].freeze

  def initialize(insight)
    @insight = insight
  end

  def title
    return insight.title if generated_in_current_locale?

    interpolate(title_key, title_extras) || insight.title
  end

  def body
    return insight.body if generated_in_current_locale?

    interpolate(template_key) || insight.body
  end

  private
    attr_reader :insight

    def interpolate(key, extras = {})
      return if key.blank? || !I18n.exists?(key)

      I18n.t(key, **facts, **extras)
    rescue I18n::MissingInterpolationArgument
      nil
    end

    def facts
      @facts ||= begin
        values = (insight.facts || {}).symbolize_keys
        if insight.period_start && (values.key?(:month) || insight.insight_type == "savings_rate_change")
          values[:month] = I18n.l(insight.period_start, format: "%B")
        end
        DATE_FACT_KEYS.each do |key|
          values[key] = self.class.localize_date(values[key]) if values[key]
        end
        values
      end
    end

    # Facts persist ISO dates (worker locale is English). Re-localize at render
    # so a Danish session doesn't keep `2026-09-20` in the sentence.
    def self.localize_date(value, format: :long)
      return value if value.blank?

      I18n.l(Date.iso8601(value.to_s), format: format).strip
    rescue Date::Error, ArgumentError
      value
    end

    def metadata
      insight.metadata || {}
    end

    def title_key
      case insight.insight_type
      when "spending_anomaly"
        direction = metadata["direction"]
        "insights.titles.spending_anomaly.#{direction}" if direction.present?
      when "cash_flow_warning"
        "insights.titles.cash_flow_warning.#{cash_flow_severity}"
      when "net_worth_milestone"
        "insights.titles.net_worth_milestone"
      when "subscription_audit"
        "insights.titles.subscription_audit"
      when "savings_rate_change"
        "insights.titles.savings_rate_change.#{savings_direction}" if savings_direction
      when "idle_cash"
        "insights.titles.idle_cash"
      when "budget_at_risk"
        "insights.titles.budget_at_risk"
      when "budget_on_track"
        "insights.titles.budget_on_track"
      end
    end

    def template_key
      case insight.insight_type
      when "spending_anomaly"
        direction = metadata["direction"]
        "insights.templates.spending_anomaly.#{direction}" if direction.present?
      when "cash_flow_warning"
        "insights.templates.cash_flow_warning.#{cash_flow_severity}"
      when "net_worth_milestone"
        "insights.templates.net_worth_milestone"
      when "subscription_audit"
        "insights.templates.subscription_audit"
      when "savings_rate_change"
        "insights.templates.#{savings_template_suffix}" if savings_template_suffix
      when "idle_cash"
        "insights.templates.idle_cash"
      when "budget_at_risk"
        severity = (metadata["over_category_ids"] || []).any? ? "over" : "near"
        "insights.templates.budget_at_risk.#{severity}"
      when "budget_on_track"
        "insights.templates.budget_on_track"
      end
    end

    def title_extras
      return { count: facts[:count].to_i } if insight.insight_type == "budget_at_risk"

      {}
    end

    def generated_in_current_locale?
      stored = metadata["locale"].presence
      return false if stored.blank?

      stored.to_s == I18n.locale.to_s
    end

    def cash_flow_severity
      metadata["negative"] ? "negative" : "low"
    end

    def savings_direction
      return if metadata["current_rate"].nil? || metadata["previous_rate"].nil?

      metadata["current_rate"].to_f >= metadata["previous_rate"].to_f ? "up" : "down"
    end

    def savings_template_suffix
      direction = savings_direction
      return unless direction
      return "savings_rate_change.down_negative" if direction == "down" && current_rate_negative?

      "savings_rate_change.#{direction}"
    end

    # Generators persist a rounded rate in metadata; a true small negative can
    # round to -0.0, which is not `#negative?`. Prefer the unrounded flag.
    def current_rate_negative?
      return metadata["current_rate_negative"] unless metadata["current_rate_negative"].nil?

      metadata["current_rate"].to_f.negative?
    end
end
