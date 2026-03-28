class CreateKrakenItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :kraken_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name

      t.string :institution_id
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      t.string :status, default: "good"
      t.boolean :scheduled_for_deletion, default: false
      t.boolean :pending_account_setup, default: false

      t.datetime :sync_start_date

      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload

      t.text :api_key
      t.text :api_secret

      t.timestamps
    end

    add_index :kraken_items, :status

    create_table :kraken_accounts, id: :uuid do |t|
      t.references :kraken_item, null: false, foreign_key: true, type: :uuid

      t.string :name
      t.string :account_id
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.string :account_status
      t.string :account_type
      t.string :provider

      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      t.timestamps
    end

    add_index :kraken_accounts, :account_id
    add_index :kraken_accounts, [ :kraken_item_id, :account_id ],
              unique: true,
              where: "(account_id IS NOT NULL)",
              name: "index_kraken_accounts_on_item_and_account_id"
  end
end
