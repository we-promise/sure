class CreateRecurringTransactions < ActiveRecord::Migration[7.2]
  def change
    create_table :recurring_transactions, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :merchant, null: false, foreign_key: true, type: :uuid
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.integer :expected_day_of_month, null: false
      t.date :last_occurrence_date, null: false
      t.date :next_expected_date, null: false
      t.string :status, default: "active", null: false
      t.integer :occurrence_count, default: 0, null: false

      t.timestamps
    end

    add_index :recurring_transactions, [ :family_id, :merchant_id, :amount, :currency ],
              unique: true,
              name: "idx_recurring_txns_on_family_merchant_amount_currency"
    add_index :recurring_transactions, [ :family_id, :status ]
    add_index :recurring_transactions, :next_expected_date
  end
end
