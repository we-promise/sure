class AddTargetModeToGoals < ActiveRecord::Migration[7.2]
  def change
    # "6 months of expenses" is a moving target: the amount that covers six
    # months in January is not the one that covers six months in December.
    # `target_amount` stays the single source of truth — a monthly job
    # rewrites it — so every existing aggregate (remaining_amount,
    # progress_percent, Goal.summary_for) keeps working untouched, with no
    # effective_target_amount that every caller would have to know about.
    add_column :goals, :target_mode, :string, null: false, default: "fixed"
    add_column :goals, :target_months, :integer
    add_check_constraint :goals, "target_mode IN ('fixed','months_of_expenses')",
                         name: "chk_goals_target_mode_enum"
  end
end
