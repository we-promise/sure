class AllowNullTargetAmountForRetirementGoals < ActiveRecord::Migration[7.2]
  # Retirement plans derive their target from the forecast (PR3), so they
  # are created before any target exists. Relax the column NOT NULL but
  # keep the guarantee for savings goals via a type-aware check, so base
  # Goal rows still require a target at the DB level.
  def up
    change_column_null :goals, :target_amount, true
    add_check_constraint :goals,
      "type <> 'Goal' OR target_amount IS NOT NULL",
      name: "chk_goals_savings_requires_target"
  end

  def down
    remove_check_constraint :goals, name: "chk_goals_savings_requires_target"
    change_column_null :goals, :target_amount, false
  end
end
