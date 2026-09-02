class AddVariableRateTrackingToLoans < ActiveRecord::Migration[7.2]
  def change
    add_column :loans, :variable_rate_schedule, :jsonb, default: {}, null: false
    add_column :loans, :start_date, :date

    create_table :loan_amortizations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :loan, type: :uuid, foreign_key: true, null: false
      t.integer :payment_number, null: false
      t.date :payment_date, null: false
      t.decimal :payment_amount, precision: 19, scale: 4, null: false
      t.decimal :principal_payment, precision: 19, scale: 4, null: false
      t.decimal :interest_payment, precision: 19, scale: 4, null: false
      t.decimal :beginning_balance, precision: 19, scale: 4, null: false
      t.decimal :ending_balance, precision: 19, scale: 4, null: false
      t.decimal :interest_rate, precision: 10, scale: 3, null: false
      t.string :schedule_signature, null: false

      t.timestamps
    end

    add_index :loan_amortizations, [ :loan_id, :payment_number ], unique: true
    add_index :loan_amortizations, [ :loan_id, :payment_date ]
    add_index :loan_amortizations, [ :loan_id, :schedule_signature ]
  end
end
