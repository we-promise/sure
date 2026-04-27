module SavingsGoals
  # Auto-funds active savings goals for one family from a budget's monthly
  # surplus. Idempotent per (goal, budget) pair: the partial unique index
  # on savings_contributions guards against double-funding even if this
  # runs concurrently. An advisory lock per family serializes execution
  # at the application level for cleaner error messages.
  #
  # Triggered by:
  #   - SavingsGoals::ScheduleAutoFundsJob (monthly cron, last-month budget)
  #   - User clicking "Auto-fund this month" on the Savings tab
  class AutoFundJob < ApplicationJob
    queue_as :medium_priority

    def perform(family_id, budget_id = nil)
      family = Family.find_by(id: family_id)
      return unless family

      budget = budget_id ? family.budgets.find_by(id: budget_id) : default_budget(family)
      return unless budget

      Family.transaction do
        acquire_lock!(family.id)
        run(family, budget)
      end
    end

    private
      def default_budget(family)
        family.budgets.where(start_date: Date.current.beginning_of_month).first
      end

      # Postgres advisory xact lock — auto-released on commit/rollback.
      # Hashed key is a stable 63-bit positive int derived from family id;
      # we still bind through sanitize_sql so Brakeman's static analysis
      # doesn't flag the call site as raw SQL interpolation.
      def acquire_lock!(family_id)
        key = Digest::SHA1.hexdigest("savings_auto_fund:#{family_id}").to_i(16) % (2**63)
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?)", key ])
        )
      end

      def run(family, budget)
        summary = family.savings_summary_for(budget)
        pool = summary.surplus.to_d
        return if pool <= 0

        # Prefetch the set of goals that already have an auto contribution
        # for this budget. Avoids an N+1 lookup per goal in the loop.
        funded_goal_ids = SavingsContribution
                            .where(savings_goal_id: summary.active_goals.map(&:id),
                                   budget_id: budget.id,
                                   source: "auto")
                            .pluck(:savings_goal_id)
                            .to_set

        summary.active_goals.each do |goal|
          break if pool <= 0
          next if funded_goal_ids.include?(goal.id)

          target = goal.monthly_target_amount
          next if target.nil? || target.to_d <= 0

          remaining = goal.remaining_amount.to_d
          next if remaining <= 0

          amount = [ target.to_d, pool, remaining ].min
          next if amount <= 0

          SavingsContribution.create!(
            savings_goal: goal,
            budget: budget,
            amount: amount,
            currency: goal.currency,
            source: "auto",
            contributed_at: budget.start_date
          )

          pool -= amount
        end
      rescue ActiveRecord::RecordNotUnique
        # Another worker won a race for the same (goal, budget, source=auto)
        # row. Partial unique index rejects the duplicate. Treat as no-op.
        Rails.logger.info("AutoFundJob: skipped duplicate for family=#{family.id}, budget=#{budget.id}")
      end
  end
end
