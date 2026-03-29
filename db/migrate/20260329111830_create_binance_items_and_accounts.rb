class CreateBinanceItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :binance_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name

      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      t.string :status, default: "good"
      t.boolean :scheduled_for_deletion, default: false
      t.boolean :pending_account_setup, default: false

      t.datetime :sync_start_date
      t.jsonb :raw_payload

      t.text :api_key
      t.text :api_secret

      t.timestamps
    end

    add_index :binance_items, :status

    create_table :binance_accounts, id: :uuid do |t|
      t.references :binance_item, null: false, foreign_key: true, type: :uuid

      t.string :name
      t.string :account_type
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4

      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      t.timestamps
    end

    add_index :binance_accounts, :account_type
  end
end
