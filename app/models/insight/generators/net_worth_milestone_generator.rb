# Celebrates the family's net worth crossing a round-number milestone within
# the last 30 days. The dedup key is the milestone amount itself, so each
# milestone is only ever celebrated once.
class Insight::Generators::NetWorthMilestoneGenerator < Insight::Generator
  produces "net_worth_milestone"

  MILESTONES = [
    10_000, 25_000, 50_000, 100_000, 250_000,
    500_000, 1_000_000, 2_500_000, 5_000_000, 10_000_000
  ].freeze

  def generate
    series = balance_sheet.net_worth_series(period: Period.last_30_days)
    values = series.values
    return [] if values.size < 2

    current = money_amount(values.last.value)
    previous = money_amount(values.first.value)
    return [] if current <= previous

    milestone = MILESTONES.select { |m| previous < m && current >= m }.max
    return [] unless milestone

    [
      build_insight(
        insight_type: "net_worth_milestone",
        priority: "high",
        title: I18n.t("insights.titles.net_worth_milestone", milestone: format_whole_money(milestone)),
        template_key: "net_worth_milestone",
        facts: {
          milestone: format_whole_money(milestone),
          net_worth: format_money(current)
        },
        metadata: {
          milestone: milestone,
          net_worth: round(current, 0)
        },
        period: Period.last_30_days,
        dedup_key: "net_worth_milestone:#{milestone}"
      )
    ]
  end

  private
    def money_amount(value)
      (value.respond_to?(:amount) ? value.amount : value).to_d
    end

    def format_whole_money(amount)
      Money.new(amount, family.currency).format(precision: 0)
    end
end
