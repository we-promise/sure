class CreateSavingGoals < ActiveRecord::Migration[7.2]
  def change
    create_table :saving_goals, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.decimal :target_amount, precision: 19, scale: 4, null: false
      t.decimal :current_amount, precision: 19, scale: 4, default: 0, null: false
      t.date :target_date
      t.integer :priority, default: 0
      t.string :status, null: false, default: "active"
      t.string :color
      t.string :icon
      t.string :currency, null: false
      t.text :notes

      t.timestamps
    end

    create_table :saving_contributions, id: :uuid do |t|
      t.references :saving_goal, null: false, foreign_key: true, type: :uuid
      t.references :budget, foreign_key: true, type: :uuid
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.date :month, null: false
      t.string :source, null: false, default: "manual"
      t.string :currency, null: false

      t.timestamps
    end

    add_index :saving_goals, [:family_id, :status]
    add_index :saving_contributions, [:saving_goal_id, :month]
  end
end
