class CreateYaxiProviderRecords < ActiveRecord::Migration[7.2]
  def change
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

      t.index [ :family_id, :credential_storage_id ], unique: true
      t.index :status
    end

    create_table :yaxi_accounts, id: :uuid do |t|
      t.references :yaxi_item, null: false, foreign_key: true, type: :uuid
      t.string :external_id, null: false
      t.string :iban
      t.string :number
      t.string :bic
      t.string :name, null: false
      t.string :currency, null: false
      t.string :account_type
      t.string :account_status
      t.decimal :current_balance, precision: 19, scale: 4
      t.jsonb :raw_payload, null: false, default: {}
      t.jsonb :raw_transactions_payload, null: false, default: []
      t.timestamps

      t.index [ :yaxi_item_id, :external_id ], unique: true
    end

    create_table :yaxi_tickets, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :service, null: false
      t.jsonb :service_data
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps

      t.index :expires_at
      t.index [ :family_id, :user_id, :consumed_at ], name: "index_yaxi_tickets_on_owner_and_consumed"
    end
  end
end
