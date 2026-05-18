module InsightsHelper
  INSIGHT_ICONS = {
    "spending_anomaly"    => "trending-up",
    "cash_flow_warning"   => "alert-triangle",
    "net_worth_milestone" => "trophy",
    "subscription_audit"  => "credit-card",
    "savings_rate_change" => "piggy-bank",
    "idle_cash"           => "clock",
    "budget_on_track"     => "check-circle",
    "budget_at_risk"      => "alert-circle"
  }.freeze

  def insight_icon(insight_type)
    INSIGHT_ICONS.fetch(insight_type.to_s, "zap")
  end

  def insight_icon_color_class(priority)
    case priority.to_s
    when "high"   then "text-destructive"
    when "medium" then "text-warning"
    else               "text-secondary"
    end
  end

  def insight_priority_label(priority)
    I18n.t("insights.priority.#{priority}", default: priority.to_s.humanize)
  end
end
