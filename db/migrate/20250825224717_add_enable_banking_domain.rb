class AddEnableBankingDomain < ActiveRecord::Migration[7.2]
  def change
    create_table :enable_banking_items, id: :uuid do |t|
      t.references :family, null: false, type: :uuid, foreign_key: true
      t.string :session_id
      t.timestamp :valid_until
      t.string :name
      t.string :aspsp_name
      t.string :aspsp_country
      t.string :status, default: "good"
      t.string :logo_url
      t.boolean :scheduled_for_deletion, default: false
      t.jsonb :raw_payload

      t.timestamps
    end

    create_table :enable_banking_accounts, id: :uuid do |t|
      t.references :enable_banking_item, null: false, type: :uuid, foreign_key: true
      t.string :account_id
      t.string :account_type
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :available_balance, precision: 19, scale: 4
      t.string :currency
      t.string :name
      t.string :mask
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload, default: {}

      t.timestamps
    end

    add_reference :accounts, :enable_banking_account, null: true, foreign_key: true, type: :uuid
  end
end
