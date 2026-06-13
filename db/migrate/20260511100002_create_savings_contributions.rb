class CreateSavingsContributions < ActiveRecord::Migration[7.2]
  def change
    create_table :savings_contributions, id: :uuid do |t|
      t.references :savings_goal, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.string :source, null: false, default: "manual"
      t.date :contributed_at, null: false
      t.text :notes

      t.timestamps
    end

    add_index :savings_contributions, [ :savings_goal_id, :contributed_at ]
    add_check_constraint :savings_contributions,
                         "amount > 0",
                         name: "chk_savings_contributions_amount_positive"
    add_check_constraint :savings_contributions,
                         "source IN ('manual','initial')",
                         name: "chk_savings_contributions_source_enum"
  end
end
