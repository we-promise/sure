class Goals::ProgressRingComponent < ApplicationComponent
  def initialize(goal:, size: 180)
    @goal = goal
    @size = size
  end

  attr_reader :goal, :size

  def percent
    goal.progress_percent
  end

  def amount_label
    goal.current_balance_money.format
  end

  def target_label
    goal.target_amount_money.format
  end

  def remaining_label
    goal.remaining_amount_money.format
  end

  def percent_text_class
    case goal.status
    # `funded` is a reserve sitting at its floor — the same "nothing to do
    # here" as a one-off that reached its target, and it should read as such.
    when :reached, :funded then "text-success"
    else "text-primary"
    end
  end
end
