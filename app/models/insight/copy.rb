# Titles and bodies are persisted as finished prose at generation time (often
# English, or LLM-written English). Facts + type/metadata are enough to
# interpolate the i18n templates at render, so a locale switch does not wait
# for a nightly rewrite.
class Insight::Copy
  def initialize(insight)
    @insight = insight
  end

  def title
    interpolate(title_key, title_extras) || insight.title
  end

  def body
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
        values
      end
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
      return "savings_rate_change.down_negative" if direction == "down" && metadata["current_rate"].to_f.negative?

      "savings_rate_change.#{direction}"
    end
end
