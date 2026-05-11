class Goals::CardComponent < ApplicationComponent
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
    when :behind then "var(--color-yellow-600)"
    when :on_track then "var(--color-green-500)"
    else "var(--color-gray-400)"
    end
  end

  def linked_accounts
    @linked_accounts ||= goal.linked_accounts.to_a
  end

  def linked_accounts_count_label
    I18n.t("goals.goal_card.accounts", count: linked_accounts.size)
  end

  # Single screen-reader sentence for the card's title <a> aria-label.
  # Without this, the whole-card link would inherit every nested text node
  # as its accessible name (>15 strings on a typical card).
  def aria_label
    status_text = I18n.t("goals.status.#{goal.display_status}")
    progress_text = I18n.t("goals.goal_card.aria_progress",
                           percent: progress_percent,
                           target: goal.target_amount_money.format)
    [ goal.name, status_text, progress_text ].join(", ")
  end

  def secondary_line
    if goal.completed?
      I18n.t("goals.goal_card.completed")
    elsif goal.target_date.nil?
      I18n.t("goals.goal_card.no_target_date")
    else
      days = (goal.target_date - Date.current).to_i
      if days >= 0
        I18n.t("goals.goal_card.days_left_by", count: days, date: I18n.l(goal.target_date, format: :long))
      else
        I18n.t("goals.goal_card.past_due")
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

  def pace_line
    return nil if goal.archived? || goal.paused? || goal.completed? || goal.status == :reached

    avg = Money.new(goal.average_monthly_contribution, goal.currency).format
    target = goal.monthly_target_amount ? Money.new(goal.monthly_target_amount, goal.currency).format : nil
    if target
      I18n.t("goals.goal_card.pace_with_target", avg: avg, target: target)
    else
      I18n.t("goals.goal_card.pace_no_target", avg: avg)
    end
  end

  def footer_line
    if goal.archived?
      I18n.t("goals.goal_card.footer_archived")
    elsif goal.paused?
      I18n.t("goals.goal_card.footer_paused")
    elsif goal.completed? || goal.status == :reached
      I18n.t("goals.goal_card.footer_reached")
    elsif goal.status == :behind && goal.monthly_target_amount
      catch_up = Money.new(goal.monthly_target_amount, goal.currency).format
      I18n.t("goals.goal_card.footer_catch_up", amount: catch_up)
    elsif goal.status == :no_target_date
      I18n.t("goals.goal_card.footer_no_deadline")
    else
      days = goal.last_contribution_days_ago
      if days.nil?
        I18n.t("goals.goal_card.footer_no_contributions")
      elsif days.zero?
        I18n.t("goals.goal_card.footer_last_today")
      else
        I18n.t("goals.goal_card.footer_last_days", count: days)
      end
    end
  end
end
