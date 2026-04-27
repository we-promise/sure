class Savings::GoalCardComponent < ApplicationComponent
  attr_reader :goal

  def initialize(goal:)
    @goal = goal
  end

  def state_badge_classes
    case goal.state
    when "active"    then "bg-success/10 text-success"
    when "paused"    then "bg-warning/10 text-warning"
    when "completed" then "bg-success/20 text-success"
    when "archived"  then "bg-container-inset text-secondary"
    else "bg-container-inset text-secondary"
    end
  end

  def target_summary
    return goal.account.name if goal.target_date.nil?
    "#{goal.target_date.strftime('%b %Y')} · #{goal.account.name}"
  end
end
