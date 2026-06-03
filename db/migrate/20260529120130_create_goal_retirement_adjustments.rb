class CreateGoalRetirementAdjustments < ActiveRecord::Migration[7.2]
  def change
    create_table :goal_retirement_adjustments, id: :uuid do |t|
      t.references :goal_retirement, type: :uuid, null: false,
        foreign_key: { to_table: :goals, on_delete: :cascade }, index: true
      t.integer :from_age, null: false
      t.integer :to_age
      t.decimal :amount_today, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.string :label, null: false
      t.string :icon
      t.integer :ordinal, null: false, default: 0

      t.timestamps
    end
  end
end
