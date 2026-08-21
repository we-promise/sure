class CreateYaxiItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    # Create provider items table (stores per-family connections)
    # NOTE: Credentials are stored GLOBALLY in the 'settings' table via Provider::Configurable
    # This table only stores connection metadata per family
    create_table :yaxi_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :connection_id
      t.string :institution_name
      t.string :logo_id
      t.string :credential_storage_id, null: false
      t.text :credential_secret, null: false
      t.string :status, null: false, default: "connecting"
      t.datetime :last_refreshed_at

      t.timestamps
    end

    add_index :yaxi_items, :status
    add_index :yaxi_items, [ :family_id, :credential_storage_id ], unique: true

    # Create provider accounts table (stores individual account data from provider)
    create_table :yaxi_accounts, id: :uuid do |t|
      t.references :yaxi_item, null: false, foreign_key: true, type: :uuid
      t.string :external_id, null: false
      t.string :iban
      t.string :number
      t.string :bic
      t.string :name, null: false
      t.string :currency, null: false
      t.decimal :current_balance, precision: 19, scale: 4
      t.string :account_status
      t.string :account_type
      t.jsonb :raw_payload, null: false, default: {}
      t.jsonb :raw_transactions_payload, null: false, default: []

      t.timestamps
    end

    add_index :yaxi_accounts, [ :yaxi_item_id, :external_id ], unique: true
  end
end
