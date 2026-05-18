class Insight::Generators::NetWorthMilestoneGenerator < Insight::Generator
  MILESTONES = [ 1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000 ].freeze

  def generate
    return [] if family.accounts.visible.none?

    balance_sheet = family.balance_sheet
    current = balance_sheet.net_worth.to_f
    return [] if current <= 0

    crossed = highest_crossed_milestone(balance_sheet, current)
    all_time_high = all_time_high?(balance_sheet, current)

    return [] unless crossed || all_time_high

    if crossed
      metadata = { "net_worth" => current.round(2), "milestone" => crossed, "kind" => "milestone" }
      title = "Net worth passed #{format_money(crossed)}"
      fallback = "Your net worth has crossed #{format_money(crossed)} and now sits at #{format_money(current)}. Nice progress."
      facts = { signal: "net_worth_milestone", net_worth: format_money(current), milestone: format_money(crossed) }
      dedup = "net_worth_milestone:milestone:#{crossed}"
    else
      metadata = { "net_worth" => current.round(2), "kind" => "all_time_high" }
      title = "New all-time high net worth"
      fallback = "Your net worth just reached a new all-time high of #{format_money(current)}."
      facts = { signal: "net_worth_all_time_high", net_worth: format_money(current) }
      dedup = "net_worth_milestone:all_time_high:#{Date.current.strftime('%Y-%m')}"
    end

    [
      GeneratedInsight.new(
        insight_type: "net_worth_milestone",
        priority: "high",
        title: title,
        body: generate_body(facts: facts, fallback: fallback),
        metadata: metadata,
        currency: currency,
        period_start: nil,
        period_end: nil,
        dedup_key: dedup
      )
    ]
  end

  private
    def highest_crossed_milestone(balance_sheet, current)
      previous = previous_net_worth(balance_sheet)
      return nil if previous.nil?

      MILESTONES.select { |m| previous < m && current >= m }.max
    end

    def all_time_high?(balance_sheet, current)
      series = net_worth_values(balance_sheet, Period.last_30_days)
      return false if series.size < 2

      prior_max = series[0..-2].max
      prior_max.present? && current > prior_max
    end

    def previous_net_worth(balance_sheet)
      series = net_worth_values(balance_sheet, Period.last_30_days)
      series.size >= 2 ? series.first : nil
    end

    def net_worth_values(balance_sheet, period)
      series = balance_sheet.net_worth_series(period: period)
      series.values.map { |v| v.value.to_f }
    rescue StandardError
      []
    end
end
