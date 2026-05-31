class AddAnnuitySettingsToLoans < ActiveRecord::Migration[7.2]
  def change
    add_column :loans, :annuity_enabled, :boolean, null: false, default: false
    add_column :loans, :started_on, :date
    add_column :loans, :payment_cadence, :string, null: false, default: "monthly"

    create_table :loan_rate_periods, id: :uuid do |t|
      t.references :loan, null: false, type: :uuid, foreign_key: true
      t.date :starts_on, null: false
      t.decimal :annual_rate, precision: 10, scale: 3, null: false
      t.decimal :payment_amount, precision: 19, scale: 4

      t.timestamps
    end

    add_index :loan_rate_periods, [ :loan_id, :starts_on ], unique: true
  end
end
