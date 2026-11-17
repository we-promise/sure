# Celebrates the family's net worth crossing a round-number milestone within
# the last 30 days. A crossing counts only when net worth had stayed below the
# milestone for the 30 days before it and has held at or above it since, and
# only for the highest milestone net worth reached in the window. So a drop
# never surfaces a lower milestone passed earlier, and a dip-and-recovery does
# not announce the same milestone twice.
#
# The dedup key is the milestone amount itself, so a milestone row is reused
# for life: a dismissal is permanent, and an expired one resurfaces only after
# net worth spent a full window below the milestone and crossed it again.
class Insight::Generators::NetWorthMilestoneGenerator < Insight::Generator
  produces "net_worth_milestone"

  # Known limitation: milestones are family-currency units, tuned for
  # dollar/euro-scale currencies. In JPY-scale currencies the lower rungs are
  # trivially small ($10k ≈ ¥1.5M would be the right first rung, not ¥10k).
  MILESTONES = [
    10_000, 25_000, 50_000, 100_000, 250_000,
    500_000, 1_000_000, 2_500_000, 5_000_000, 10_000_000
  ].freeze

  # How long net worth must have stayed below a milestone before crossing it
  # for the crossing to count. Matches the look-back window.
  QUIET_PERIOD = 30.days

  Point = Data.define(:date, :amount)

  def generate
    window = Period.last_30_days
    history = net_worth_history(window)
    return [] if history.size < 2

    current = history.last.amount
    peak = history.select { |point| point.date >= window.start_date }.map(&:amount).max
    milestone = MILESTONES.select { |m| m <= peak }.max
    return [] unless milestone && current >= milestone
    return [] unless freshly_crossed?(history, milestone, window)

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
        # The milestone alone is the signal. Net worth itself drifts daily for
        # the ~30 days the crossing stays in the series window — storing it
        # here would rewrite the body and resurrect dismissals every night.
        metadata: {
          milestone: milestone
        },
        period: window,
        dedup_key: "net_worth_milestone:#{milestone}"
      )
    ]
  end

  private
    # The window plus the quiet period before it, so a crossing near the start
    # of the window can still be checked against the days that preceded it.
    def net_worth_history(window)
      period = Period.custom(start_date: window.start_date - QUIET_PERIOD, end_date: window.end_date)
      balance_sheet.net_worth_series(period: period).values.map do |value|
        Point.new(date: value.date, amount: money_amount(value.value))
      end
    end

    # The last upward crossing must fall inside the window, and net worth must
    # have stayed below the milestone for the quiet period before it. Callers
    # guarantee current >= milestone, so it has held since that crossing.
    def freshly_crossed?(history, milestone, window)
      last_below = history.rindex { |point| point.amount < milestone }
      return false unless last_below

      crossed_on = history[last_below + 1].date
      quiet_since = crossed_on - QUIET_PERIOD

      crossed_on > window.start_date &&
        history.none? { |point| point.date >= quiet_since && point.date < crossed_on && point.amount >= milestone }
    end

    def money_amount(value)
      (value.respond_to?(:amount) ? value.amount : value).to_d
    end

    def format_whole_money(amount)
      Money.new(amount, family.currency).format(precision: 0)
    end
end
