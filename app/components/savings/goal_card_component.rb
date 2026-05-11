class Savings::GoalCardComponent < ApplicationComponent
  RING_SIZE = 64
  RING_STROKE = 6

  def initialize(goal:)
    @goal = goal
  end

  attr_reader :goal

  def progress_percent
    goal.progress_percent
  end

  def ring_color
    case goal.status
    when :reached then "var(--color-green-600)"
    when :behind then "var(--color-yellow-500)"
    when :on_track then "var(--text-primary)"
    else "var(--text-subdued)"
    end
  end

  def linked_accounts
    @linked_accounts ||= goal.linked_accounts.to_a
  end

  def linked_accounts_count_label
    I18n.t("savings_goals.goal_card.accounts", count: linked_accounts.size)
  end

  def secondary_line
    if goal.completed?
      I18n.t("savings_goals.goal_card.completed")
    elsif goal.target_date.nil?
      I18n.t("savings_goals.goal_card.no_target_date")
    else
      days = (goal.target_date - Date.current).to_i
      if days >= 0
        I18n.t("savings_goals.goal_card.days_left_by", count: days, date: I18n.l(goal.target_date, format: :long))
      else
        I18n.t("savings_goals.goal_card.past_due")
      end
    end
  end

  def ring_circumference
    @ring_circumference ||= 2 * Math::PI * ring_radius
  end

  def ring_radius
    @ring_radius ||= (RING_SIZE - RING_STROKE) / 2.0
  end

  def ring_offset
    pct = [ [ progress_percent.to_i, 0 ].max, 100 ].min
    ring_circumference * (1 - pct / 100.0)
  end
end
