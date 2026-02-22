class CreateGoals < ActiveRecord::Migration[7.2]
  def change
    create_table :goals, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.text :description
      t.string :goal_type, null: false, default: "custom"
      t.decimal :target_amount, precision: 19, scale: 4, null: false
      t.decimal :current_amount, precision: 19, scale: 4, null: false, default: 0
      t.date :target_date
      t.string :lucide_icon, default: "target"
      t.string :color, default: "#6366f1"
      t.integer :priority, default: 0
      t.boolean :is_completed, default: false, null: false
      t.string :currency, null: false
      t.timestamps
    end
  end
end
