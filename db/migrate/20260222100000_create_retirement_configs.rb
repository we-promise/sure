class CreateRetirementConfigs < ActiveRecord::Migration[7.2]
  def change
    create_table :retirement_configs, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid, index: { unique: true }
      t.string :country, null: false, default: "DE"
      t.string :pension_system, null: false, default: "de_grv"
      t.integer :birth_year, null: false
      t.integer :retirement_age, null: false, default: 67
      t.decimal :target_monthly_income, precision: 19, scale: 4, null: false, default: 3000.0
      t.string :currency, null: false, default: "EUR"
      t.decimal :expected_return_pct, precision: 5, scale: 2, null: false, default: 7.0
      t.decimal :inflation_pct, precision: 5, scale: 2, null: false, default: 2.0
      t.decimal :tax_rate_pct, precision: 5, scale: 2, null: false, default: 26.38
      t.decimal :current_monthly_savings, precision: 19, scale: 4, null: false, default: 0.0
      t.integer :contribution_start_year
      t.decimal :expected_annual_points, precision: 5, scale: 2
      t.decimal :rentenwert, precision: 8, scale: 2

      t.timestamps
    end
  end
end
