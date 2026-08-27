module GoalsHelper
  # Completing a goal releases the money it was holding, so both places that
  # offer it — the header menu and the celebration panel — ask first, and ask
  # the same question. Built here rather than twice inline: the two wordings
  # drifting apart is how one of them ends up describing the wrong consequence.
  def goal_complete_confirm(goal)
    body = if goal.progress_percent < 100
      t("goals.show.confirm_complete_body_short",
        progress: goal.progress_percent,
        saved: goal.current_balance_money.format(precision: 0),
        target: goal.target_amount_money.format(precision: 0))
    else
      t("goals.show.confirm_complete_body")
    end

    CustomConfirm.new(
      title: t("goals.show.confirm_complete_title"),
      body: body,
      btn_text: t("goals.show.confirm_complete_cta")
    )
  end

  # Fixed earmarks on `account` held by goals OTHER than the one being
  # edited, read from a pooled map loaded once per render
  # (Goal.pooled_allocations_for) rather than per account — the form lists
  # every fundable account, so a per-account query is a guaranteed N+1.
  #
  # Excluding the current goal is what makes the warning trustworthy:
  # `Account#goal_earmarked_total` counts every goal, so reopening a goal
  # that earmarks 5,000 on a 6,000 account would leave 1,000 of apparent
  # headroom, and re-entering the same 5,000 would trip a message although
  # nothing changed.
  #
  # Whole-balance links carry a nil allocated_amount and contribute zero:
  # they reserve no fixed slice. That is the right reading here — what they
  # do claim is guarded separately, at write time, by GoalAccount.
  def earmarked_by_other_goals(account, pooled:, current_goal: nil)
    (pooled[account.id] || [])
      .reject { |row| current_goal&.persisted? && row[:goal_id] == current_goal.id }
      .sum { |row| row[:allocated_amount].to_d }
  end
end
