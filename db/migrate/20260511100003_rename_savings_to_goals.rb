class RenameSavingsToGoals < ActiveRecord::Migration[7.2]
  def change
    rename_table :savings_goals, :goals
    rename_table :savings_contributions, :goal_contributions
    rename_table :savings_goal_accounts, :goal_accounts

    rename_column :goal_contributions, :savings_goal_id, :goal_id
    rename_column :goal_accounts, :savings_goal_id, :goal_id
  end
end
