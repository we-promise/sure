class CreateInterestAccruals < ActiveRecord::Migration[7.2]
  def change
    create_table :interest_accruals, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :depository, type: :uuid, null: false, foreign_key: true
      t.date :date, null: false
      t.decimal :balance_used, precision: 19, scale: 4, null: false
      t.decimal :daily_rate, precision: 15, scale: 12, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.boolean :paid_out, default: false, null: false

      t.timestamps
    end

    add_index :interest_accruals, [ :depository_id, :date ], unique: true
    add_index :interest_accruals, [ :depository_id, :paid_out ]
  end
end
