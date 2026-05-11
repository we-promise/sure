class Savings::GoalCardComponent < ApplicationComponent
  def initialize(goal:)
    @goal = goal
  end

  attr_reader :goal

  def progress_percent
    goal.progress_percent
  end

  def bar_color_style
    case goal.status
    when :reached then "var(--color-green-600)"
    when :behind then "var(--color-yellow-500)"
    when :on_track then "var(--text-primary)"
    else "var(--color-gray-400)"
    end
  end

  def linked_accounts
    @linked_accounts ||= goal.linked_accounts.to_a
  end

  def linked_accounts_count_label
    n = linked_accounts.size
    I18n.t("savings_goals.goal_card.accounts", count: n)
  end

  def secondary_line
    if goal.completed?
      I18n.t("savings_goals.goal_card.completed")
    elsif goal.target_date.nil?
      I18n.t("savings_goals.goal_card.no_target_date")
    else
      days = (goal.target_date - Date.current).to_i
      if days >= 0
        I18n.t("savings_goals.goal_card.days_left", count: days, date: I18n.l(goal.target_date, format: :long))
      else
        I18n.t("savings_goals.goal_card.past_due")
      end
    end
  end
end
