class CreateGoalRetirementStatements < ActiveRecord::Migration[7.2]
  def change
    create_table :goal_retirement_statements, id: :uuid do |t|
      t.references :goal_retirement, type: :uuid, null: false,
        foreign_key: { to_table: :goals, on_delete: :cascade }, index: true
      t.references :pension_source, type: :uuid, null: false,
        foreign_key: { on_delete: :cascade }, index: true
      t.date :received_on, null: false
      t.decimal :projected_monthly_amount, precision: 19, scale: 4, null: false
      t.string :projected_currency, null: false
      t.integer :projected_at_age
      t.decimal :current_points, precision: 8, scale: 2
      t.text :raw_source_doc
      t.text :notes
      t.boolean :deleted, null: false, default: false

      t.timestamps
    end

    add_index :goal_retirement_statements, [ :pension_source_id, :received_on ],
      where: "deleted = false",
      name: "index_retirement_statements_active_by_received_on"
  end
end
