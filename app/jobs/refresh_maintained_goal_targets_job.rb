# Keeps "N months of expenses" reserves honest. Their floor is a moving
# number: what covered six months last January does not cover six months
# today. Runs on the 1st of each month, after a full month of spending has
# landed.
#
# Writes `target_amount` rather than deriving a target on read, so every
# aggregate that already reads it keeps working — see Goal::TARGET_MODES.
class RefreshMaintainedGoalTargetsJob < ApplicationJob
  queue_as :scheduled

  def perform
    scope = Goal.where(kind: "maintained", target_mode: "months_of_expenses")
                .where.not(state: Goal::RELEASED_STATES)

    scope.find_each do |goal|
      refresh(goal)
    end
  end

  private
    def refresh(goal)
      previous = goal.target_amount.to_d
      updated = goal.refresh_target_from_expenses!

      return if updated.nil? || updated == previous

      Rails.logger.info(
        "RefreshMaintainedGoalTargetsJob: goal #{goal.id} target #{previous} -> #{updated}"
      )
    rescue ActiveRecord::RecordInvalid => e
      # The reserve keeps the target it had. Surfaced in the support UI
      # rather than only the application log: a reserve quietly frozen at a
      # stale floor is invisible to the user, who has no reason to suspect
      # the figure stopped moving.
      DebugLogEntry.capture(
        category: "goals",
        level: "error",
        message: "Could not refresh maintained goal target: #{e.message}",
        source: self.class.name,
        family: goal.family,
        metadata: {
          goal_id: goal.id,
          target_months: goal.target_months,
          previous_target_amount: previous.to_s
        }
      )
    end
end
