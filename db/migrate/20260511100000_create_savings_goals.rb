class CreateSavingsGoals < ActiveRecord::Migration[7.2]
  def change
    create_table :savings_goals, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :name, null: false
      t.decimal :target_amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.date :target_date
      t.string :color
      t.text :notes
      t.string :state, null: false, default: "active"

      t.timestamps
    end

    add_index :savings_goals, [ :family_id, :state ]
    add_check_constraint :savings_goals,
                         "char_length(name) <= 255",
                         name: "chk_savings_goals_name_length"
    add_check_constraint :savings_goals,
                         "target_amount > 0",
                         name: "chk_savings_goals_target_amount_positive"
    add_check_constraint :savings_goals,
                         "state IN ('active','paused','completed','archived')",
                         name: "chk_savings_goals_state_enum"
  end
end
