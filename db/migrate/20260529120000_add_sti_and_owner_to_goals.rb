class AddStiAndOwnerToGoals < ActiveRecord::Migration[7.2]
  def up
    add_column :goals, :type, :string, default: "Goal"
    add_column :goals, :user_id, :uuid

    execute "UPDATE goals SET type = 'Goal' WHERE type IS NULL"
    change_column_null :goals, :type, false

    add_foreign_key :goals, :users, column: :user_id, on_delete: :restrict
    add_index :goals, [ :user_id, :type ],
              where: "type = 'Goal::Retirement'",
              name: "index_goals_on_user_and_type_retirement"
    add_index :goals, [ :family_id, :type, :state ],
              name: "index_goals_on_family_type_state"

    add_check_constraint :goals,
      "type <> 'Goal::Retirement' OR user_id IS NOT NULL",
      name: "chk_goals_retirement_requires_owner"
  end

  def down
    remove_check_constraint :goals, name: "chk_goals_retirement_requires_owner"
    remove_index :goals, name: "index_goals_on_family_type_state"
    remove_index :goals, name: "index_goals_on_user_and_type_retirement"
    remove_foreign_key :goals, column: :user_id
    remove_column :goals, :user_id
    remove_column :goals, :type
  end
end
