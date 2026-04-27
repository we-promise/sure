class CreateSavingsGoals < ActiveRecord::Migration[7.2]
  def change
    create_table :savings_goals, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.decimal :target_amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.date :target_date
      t.string :color
      t.string :icon
      t.text :notes
      t.string :state, null: false, default: "active"

      t.timestamps
    end

    add_index :savings_goals, [ :family_id, :state ]
  end
end
