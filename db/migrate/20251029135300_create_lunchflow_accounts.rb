class CreateLunchflowAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :lunchflow_accounts, id: :uuid do |t|
      t.references :lunchflow_item, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :account_id
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.string :account_status
      t.string :provider

      t.index :account_id
      t.string :account_type
      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      t.timestamps
    end
  end
end
