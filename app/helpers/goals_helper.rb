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
end
