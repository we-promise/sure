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

  def insight_icon_key(insight)
    INSIGHT_ICONS.fetch(insight.insight_type, "lightbulb")
  end

  # "Savings rate · June" / "Cash flow · Next 30 days" — the card's meta line.
  # Uses the insight's stored period; falls back to the subject (account or
  # merchant name from facts) for insights without one.
  def insight_meta_line(insight)
    parts = [ t("insights.types.#{insight.insight_type}", default: insight.insight_type.humanize) ]
    parts << insight_period_label(insight)
    parts.compact.join(" · ")
  end

  # [value, caption] for the card's right-aligned key figure, from the display
  # facts stored on the row. Nil (no figure) for rows written before facts
  # were persisted — they backfill on the next nightly run.
  def insight_key_figure(insight)
    facts = insight.facts || {}
    return nil if facts.blank?

    case insight.insight_type
    when "savings_rate_change"
      return nil unless facts["change_pp"]
      sign = insight_sentiment(insight) == :positive ? "+" : "−"
      value = "#{sign}#{Insight.localize_fact_value(facts["change_pp"])}"
      [ t("insights.figures.savings_rate_delta", value: value), t("insights.figures.vs_previous") ]
    when "net_worth_milestone"
      facts["net_worth"] && [ facts["net_worth"], t("insights.figures.today") ]
    when "spending_anomaly"
      facts["projected_spend"] && [ facts["projected_spend"], t("insights.figures.on_pace") ]
    when "cash_flow_warning"
      facts["projected_low"] && [ facts["projected_low"], Insight.localize_fact_value(facts["projected_low_date"]) ]
    when "subscription_audit"
      facts["amount"] && [ facts["amount"], t("insights.figures.days_overdue", count: facts["days_overdue"].to_i) ]
    when "idle_cash"
      facts["balance"] && [ facts["balance"], t("insights.figures.idle_days", count: facts["idle_days"].to_i) ]
    when "budget_at_risk", "budget_on_track"
      facts["budget_spent_pct"] && [ t("insights.figures.percent", value: facts["budget_spent_pct"]), t("insights.figures.of_budget") ]
    end
  end

  # The contextual action for a card, built from the subject ids each
  # generator stores in metadata. Returns nil when the subject no longer
  # resolves (deleted category/account) — the card renders without a link.
  # Looks up through insight.family, not Current, so broadcast renders work.
  def insight_action(insight)
    metadata = insight.metadata || {}

    case insight.insight_type
    when "spending_anomaly"
      category = insight.family.categories.find_by(id: metadata["category_id"])
      category && {
        text: t("insights.actions.spending_anomaly", category: category.name),
        href: transactions_path(q: { categories: [ category.name ] })
      }
    when "idle_cash"
      account = insight.family.accounts.visible.find_by(id: metadata["account_id"])
      account && { text: t("insights.actions.idle_cash"), href: account_path(account) }
    when "subscription_audit"
      { text: t("insights.actions.subscription_audit"), href: recurring_transactions_path }
    when "cash_flow_warning"
      { text: t("insights.actions.cash_flow_warning"), href: recurring_transactions_path }
    when "savings_rate_change"
      return nil unless insight.period_start && insight.period_end
      { text: t("insights.actions.savings_rate_change"),
        href: transactions_path(q: { start_date: insight.period_start.to_s, end_date: insight.period_end.to_s }) }
    when "net_worth_milestone"
      { text: t("insights.actions.net_worth_milestone"), href: reports_path }
    when "budget_at_risk", "budget_on_track"
      return nil unless insight.period_start
      { text: t("insights.actions.budget"), href: budget_path(Budget.date_to_param(insight.period_start)) }
    end
  end

  # Sentiment picks the color; priority only orders the feed. The two are
  # orthogonal — a big savings-rate improvement is high priority AND good news,
  # and must not render red. Red is reserved for a projected-negative balance,
  # matching the app's wider rule that even negative amounts aren't red.
  def insight_icon_color(insight)
    case insight_sentiment(insight)
    when :positive then "success"
    when :negative then "destructive"
    when :warning then "warning"
    else "default"
    end
  end

  # CSS color for the tinted icon circle (FilledIcon-style, color-mix'd to a
  # 10% tint) — CSS variables so dark mode retunes automatically.
  def insight_icon_css_color(insight)
    case insight_sentiment(insight)
    when :positive then "var(--color-success)"
    when :negative then "var(--color-destructive)"
    when :warning then "var(--color-warning)"
    else "var(--color-gray-500)"
    end
  end

  # Derived from type + the direction already stored in metadata, so rows
  # written before a metadata-shape change degrade to :warning, never :negative.
  def insight_sentiment(insight)
    metadata = insight.metadata || {}

    case insight.insight_type
    when "net_worth_milestone", "budget_on_track"
      :positive
    when "savings_rate_change"
      metadata["current_rate"].to_f >= metadata["previous_rate"].to_f ? :positive : :warning
    when "spending_anomaly"
      metadata["direction"] == "below" ? :positive : :warning
    when "cash_flow_warning"
      metadata["negative"] ? :negative : :warning
    when "budget_at_risk"
      :warning
    else
      :neutral
    end
  end

  private
    # "June" for month-aligned periods, "Next 30 days" / "Last 30 days" for
    # rolling windows, an explicit range otherwise; subject name (account,
    # merchant) for insights without a period.
    def insight_period_label(insight)
      start_date = insight.period_start
      end_date = insight.period_end

      if start_date.nil? || end_date.nil?
        facts = insight.facts || {}
        return facts["account"] || facts["name"]
      end

      if start_date == start_date.beginning_of_month && end_date == start_date.end_of_month
        format = start_date.year == Date.current.year ? "%B" : "%B %Y"
        return I18n.l(start_date, format: format)
      end

      days = (end_date - start_date).to_i
      if start_date >= Date.current - 1
        t("insights.meta.next_n_days", count: days)
      elsif end_date >= Date.current - 1
        t("insights.meta.last_n_days", count: days)
      else
        t("insights.meta.date_range", from: I18n.l(start_date, format: :short), to: I18n.l(end_date, format: :short))
      end
    end
end
