module InsightsHelper
  INSIGHT_ICONS = {
    "spending_anomaly" => "trending-up",
    "cash_flow_warning" => "alert-triangle",
    "net_worth_milestone" => "trophy",
    "subscription_audit" => "repeat",
    "savings_rate_change" => "piggy-bank",
    "idle_cash" => "wallet",
    "budget_at_risk" => "alert-circle",
    "budget_on_track" => "circle-check"
  }.freeze

  PRIORITY_STYLES = {
    "high" => "text-red-600 bg-red-50",
    "medium" => "text-yellow-700 bg-yellow-50",
    "low" => "text-secondary bg-surface-inset"
  }.freeze

  def insight_icon(insight)
    INSIGHT_ICONS.fetch(insight.insight_type, "sparkles")
  end

  def insight_priority_classes(insight)
    PRIORITY_STYLES.fetch(insight.priority, PRIORITY_STYLES["low"])
  end

  def insight_type_label(insight)
    t("insights.types.#{insight.insight_type}", default: insight.insight_type.humanize)
  end
end
