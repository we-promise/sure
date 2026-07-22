# Celebrates the family's net worth crossing a round-number milestone within
# the last 30 days. The dedup key is the milestone amount itself, so a
# milestone row is reused for life: a dismissal is permanent, and only a
# dip-below-and-recross within a 30-day window can resurface an expired one.
class Insight::Generators::NetWorthMilestoneGenerator < Insight::Generator
  produces "net_worth_milestone"

  # Known limitation: milestones are family-currency units, tuned for
  # dollar/euro-scale currencies. In JPY-scale currencies the lower rungs are
  # trivially small ($10k ≈ ¥1.5M would be the right first rung, not ¥10k).
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
          milestone: money_fact(milestone, precision: 0),
          net_worth: money_fact(current)
        },
        # The milestone alone is the signal. Net worth itself drifts daily for
        # the ~30 days the crossing stays in the series window — storing it
        # here would rewrite the body and resurrect dismissals every night.
        metadata: {
          milestone: milestone
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
