class CreateBankExternalAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :bank_external_accounts, id: :uuid do |t|
      t.references :bank_connection, type: :uuid, null: false, foreign_key: true
      t.string :provider_account_id, null: false
      t.string :name
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :available_balance, precision: 19, scale: 4
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload
      t.datetime :balance_date

      t.timestamps
    end

    add_index :bank_external_accounts, [ :bank_connection_id, :provider_account_id ], unique: true, name: "index_bank_ext_accounts_on_conn_and_provider_id"
  end
end
