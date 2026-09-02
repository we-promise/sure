class Goals::ProgressRingComponent < ApplicationComponent
  def initialize(goal:, size: 180)
    @goal = goal
    @size = size
  end

  attr_reader :goal, :size

  def percent
    goal.progress_percent
  end

  # The same total the headline beside this ring reports, and the same one the
  # ring is drawn from. Announcing the account balance while the visible text
  # said something else left a screen reader and a sighted reader looking at
  # the same ring and hearing two different numbers.
  def amount_label
    goal.progress_amount_money.format
  end

  # "saved" stops being the whole truth once part of the total has been spent
  # on the goal. The sighted reader gets that from the line under the figure;
  # this is the same sentence for someone who cannot see it.
  def aria_label
    if goal.any_consumption?
      t("goals.show.ring.aria_label_with_used",
             percent: percent, amount: amount_label, target: target_label,
             used: goal.consumed_amount_money.format)
    else
      t("goals.show.ring.aria_label",
             percent: percent, amount: amount_label, target: target_label)
    end
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
