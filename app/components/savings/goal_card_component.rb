class Savings::GoalCardComponent < ApplicationComponent
  def initialize(goal:)
    @goal = goal
  end

  attr_reader :goal

  def linked_accounts_label
    names = goal.linked_accounts.pluck(:name)
    case names.size
    when 0 then I18n.t("savings_goals.goal_card.no_accounts")
    when 1 then names.first
    when 2 then names.join(", ")
    else
      I18n.t("savings_goals.goal_card.n_accounts", first: names.first, count: names.size - 1)
    end
  end

  def progress_percent
    goal.progress_percent
  end

  def bar_color_class
    case goal.status
    when :reached then "bg-green-500"
    when :behind then "bg-yellow-500"
    when :on_track then "bg-blue-500"
    else "bg-gray-400"
    end
  end
end
