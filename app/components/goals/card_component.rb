class Goals::CardComponent < ApplicationComponent
  def initialize(goal:, filterable: true)
    @goal = goal
    @filterable = filterable
  end

  attr_reader :goal, :filterable

  def progress_percent
    goal.progress_percent
  end

  # Maps goal status to a DS::ProgressRing tone (the ring geometry/colors now
  # live in that primitive — see #1899).
  def ring_tone
    case goal.status
    when :reached, :on_track then :success
    when :behind then :warning
    else :neutral
    end
  end

  def linked_accounts
    @linked_accounts ||= goal.linked_accounts.to_a
  end

  # Open + unexpired pledges are preloaded on the index via the
  # `.includes(:open_pledges, ...)` chain in GoalsController#index, so
  # this is a hit on the in-memory association — no N+1.
  def has_pending_pledge?
    pending_pledges_count.positive?
  end

  def pending_pledges_count
    @pending_pledges_count ||= goal.open_pledges.size
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
                           target: goal.target_amount_money.format(precision: 0))
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

  def pace_line
    return nil if goal.archived? || goal.paused? || goal.completed? || goal.status == :reached

    avg = goal.pace_money.format(precision: 0)
    target = goal.monthly_target_amount ? Money.new(goal.monthly_target_amount, goal.currency).format(precision: 0) : nil
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
      I18n.t("goals.goal_card.footer_catch_up", amount: goal.catch_up_delta_money.format(precision: 0))
    elsif goal.status == :no_target_date
      I18n.t("goals.goal_card.footer_no_deadline")
    else
      days = goal.last_matched_pledge_days_ago
      if days.nil?
        I18n.t("goals.goal_card.footer_no_pledges")
      elsif days.zero?
        I18n.t("goals.goal_card.footer_last_today")
      else
        I18n.t("goals.goal_card.footer_last_days", count: days)
      end
    end
  end

  def footer_has_money?
    goal.status == :behind && goal.monthly_target_amount
  end
end
