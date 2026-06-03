class CreatePensionSources < ActiveRecord::Migration[7.2]
  def change
    create_table :pension_sources, id: :uuid do |t|
      t.references :goal_retirement, type: :uuid, null: false,
        foreign_key: { to_table: :goals, on_delete: :cascade }, index: true
      t.string :name, null: false
      t.string :kind, null: false
      t.string :country, null: false
      t.string :pension_system, null: false
      t.string :tax_treatment, null: false
      t.string :payout_shape, null: false
      t.integer :start_age, null: false
      t.integer :end_age
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.decimal :effective_rate_override, precision: 5, scale: 4
      t.jsonb :params, null: false, default: {}

      t.timestamps
    end

    add_check_constraint :pension_sources, "amount >= 0",
      name: "chk_pension_sources_amount_non_negative"
    add_check_constraint :pension_sources, "start_age >= 0 AND start_age <= 120",
      name: "chk_pension_sources_start_age_range"
  end
end
