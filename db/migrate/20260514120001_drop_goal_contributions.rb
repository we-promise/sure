class DropGoalContributions < ActiveRecord::Migration[7.2]
  def up
    drop_table :goal_contributions
  end

  def down
    create_table :goal_contributions, id: :uuid do |t|
      t.references :goal, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.string :source, default: "manual", null: false
      t.date :contributed_at, null: false
      t.text :notes

      t.timestamps
    end

    add_index :goal_contributions, [ :goal_id, :contributed_at ]
    add_check_constraint :goal_contributions, "amount > 0", name: "chk_savings_contributions_amount_positive"
    add_check_constraint :goal_contributions,
                         "source IN ('manual','initial')",
                         name: "chk_savings_contributions_source_enum"
  end
end
