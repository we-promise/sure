# Flags a reserve that has fallen below the level it exists to hold.
#
# High priority, unlike most of this feed. `IdleCashGenerator` is a nudge about
# money doing nothing; this is the opposite — a floor the user deliberately set
# is no longer there, and the whole point of a maintained goal is that someone
# says so. It is the one signal a reserve produces that a one-off goal cannot.
#
# The dedup key rotates monthly: a reserve can sit short for weeks while the
# user rebuilds it, and re-raising the same shortfall every night would train
# them to dismiss the feed.
class Insight::Generators::MaintainedGoalDepletedGenerator < Insight::Generator
  produces "maintained_goal_depleted"

  # A family running several drained reserves has one problem, not four. Past
  # the first couple the feed stops informing and starts scolding.
  MAX_INSIGHTS = 2

  def generate
    depleted_reserves.first(MAX_INSIGHTS).map do |goal|
      missing = goal.remaining_amount_money

      build_insight(
        insight_type: "maintained_goal_depleted",
        priority: "high",
        title: I18n.t("insights.titles.maintained_goal_depleted", goal: goal.name),
        template_key: "maintained_goal_depleted",
        facts: {
          goal: goal.name,
          missing: missing.format,
          saved: goal.current_balance_money.format,
          target: goal.target_amount_money.format
        },
        metadata: {
          goal_id: goal.id,
          missing: round(missing.amount, 0),
          target: round(goal.target_amount, 0)
        },
        dedup_key: "maintained_goal_depleted:#{goal.id}:#{month_token}"
      )
    end
  end

  private
    # Active only: a paused reserve is one the user shelved on purpose, and
    # `behind_pace?` already excludes paused goals for the same reason —
    # nagging about a goal someone deliberately put down is noise.
    #
    # Loaded through `Goal.prepared_for`, which injects the family-wide pooled
    # allocations once. Asking each goal for its status reaches `current_balance`,
    # and without that injection every reserve would re-read the whole pool.
    #
    # Ordered by shortfall so a tight MAX_INSIGHTS spends itself on the reserves
    # furthest from their floor, and stays stable between nightly runs.
    def depleted_reserves
      Goal.prepared_for(family, scope: family.goals.where(kind: "maintained", state: "active"))
          .select { |goal| goal.status == :depleted }
          .sort_by { |goal| -goal.remaining_amount.to_d }
    end
end
