# Surfaces an insight when net worth crosses a round-number milestone or hits a 30-day high.
class Insight::Generators::NetWorthMilestoneGenerator < Insight::Generator
  ROUND_MILESTONES = [
    1_000, 5_000, 10_000, 25_000, 50_000,
    100_000, 250_000, 500_000, 1_000_000
  ].freeze

  def generate
    balance_sheet = family.balance_sheet
    current_nw = balance_sheet.net_worth.to_f

    prior_period = Period.custom(
      start_date: 30.days.ago.to_date,
      end_date:   1.day.ago.to_date
    )

    prior_series = balance_sheet.net_worth_series(period: prior_period)
    return [] if prior_series.nil?

    prior_values = extract_prior_values(prior_series)
    return [] if prior_values.empty?

    prior_nw      = prior_values.last.to_f
    series_high   = prior_values.max.to_f
    thirty_day_high = current_nw >= series_high && current_nw > prior_nw

    crossed = ROUND_MILESTONES.find { |m| current_nw >= m && prior_nw < m }

    return [] unless crossed || thirty_day_high

    metadata = {
      "milestone"          => crossed,
      "current_net_worth"  => current_nw.round(2),
      "previous_net_worth" => prior_nw.round(2),
      "thirty_day_high"    => thirty_day_high
    }

    title = if thirty_day_high && crossed
      I18n.t("insights.net_worth_milestone.title_both",
             milestone: format_amount(crossed))
    elsif thirty_day_high
      I18n.t("insights.net_worth_milestone.title_30d_high")
    else
      I18n.t("insights.net_worth_milestone.title_milestone",
             milestone: format_amount(crossed))
    end

    body = generate_body(build_prompt(crossed, thirty_day_high, current_nw, prior_nw))

    [
      GeneratedInsight.new(
        insight_type: "net_worth_milestone",
        priority:     "high",
        title:        title,
        body:         body,
        metadata:     metadata,
        currency:     family.currency,
        period_start: prior_period.start_date,
        period_end:   Date.current,
        dedup_key:    "net_worth_milestone:#{crossed || "30d_high"}:#{Date.current.strftime("%Y-%m")}"
      )
    ]
  end

  private
    def extract_prior_values(series)
      return [] unless series.respond_to?(:values)

      series.values.filter_map do |point|
        val = point.try(:trend)&.try(:current) || point.try(:value) || point.try(:amount)
        val.to_f if val
      end
    end

    def build_prompt(crossed, thirty_day_high, current_nw, prior_nw)
      sym = currency_symbol
      current_fmt = "#{sym}#{current_nw.round(0).to_s(:delimited)}"
      prior_fmt   = "#{sym}#{prior_nw.round(0).to_s(:delimited)}"

      if thirty_day_high && crossed
        "Net worth crossed #{sym}#{crossed.to_s(:delimited)} and hit a 30-day high of #{current_fmt}."
      elsif thirty_day_high
        "Net worth hit a 30-day high of #{current_fmt}, up from #{prior_fmt} 30 days ago."
      else
        "Net worth crossed the #{sym}#{crossed.to_s(:delimited)} milestone, now at #{current_fmt}."
      end
    end

    def format_amount(amount)
      "#{currency_symbol}#{amount.to_s(:delimited)}"
    end
end
