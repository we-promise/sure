module InsightsHelper
  INSIGHT_ICONS = {
    "spending_anomaly" => "activity",
    "cash_flow_warning" => "alert-triangle",
    "net_worth_milestone" => "trophy",
    "subscription_audit" => "repeat",
    "savings_rate_change" => "piggy-bank",
    "idle_cash" => "wallet",
    "budget_at_risk" => "alert-triangle",
    "budget_on_track" => "circle-check"
  }.freeze

  POSITIVE_TYPES = %w[net_worth_milestone budget_on_track].freeze

  def insight_icon_key(insight)
    INSIGHT_ICONS.fetch(insight.insight_type, "sparkles")
  end

  def insight_icon_color(insight)
    return "success" if POSITIVE_TYPES.include?(insight.insight_type)

    case insight.priority
    when "high" then "destructive"
    when "medium" then "warning"
    else "default"
    end
  end
end
