class CreatePensionEntries < ActiveRecord::Migration[7.2]
  def change
    create_table :pension_entries, id: :uuid do |t|
      t.references :retirement_config, null: false, foreign_key: true, type: :uuid, index: false
      t.date :recorded_at, null: false
      t.decimal :current_points, precision: 8, scale: 4, null: false
      t.decimal :current_monthly_pension, precision: 19, scale: 4
      t.decimal :projected_monthly_pension, precision: 19, scale: 4
      t.text :notes

      t.timestamps
    end

    add_index :pension_entries, [ :retirement_config_id, :recorded_at ], unique: true
  end
end
