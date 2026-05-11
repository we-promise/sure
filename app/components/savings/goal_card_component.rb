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
    case progress_percent
    when 0...25 then "bg-gray-400"
    when 25...75 then "bg-blue-500"
    else "bg-green-600"
    end
  end
end
