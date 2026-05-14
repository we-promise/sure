class SweepExpiredGoalPledgesJob < ApplicationJob
  queue_as :scheduled

  def perform
    GoalPledge.open_and_expired_now.find_each(&:expire!)
  end
end
