class CreateProviderTables < ActiveRecord::Migration[7.2]
  def change
    create_table :provider_family_configs, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string  :provider_key, null: false
      t.jsonb   :credentials, default: {}, null: false
      t.timestamps
    end
    add_index :provider_family_configs, [ :family_id, :provider_key ], unique: true

    create_table :provider_connections, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      # Null for providers using global Rails config credentials (e.g. Plaid reads PLAID_CLIENT_ID from env).
      # Present for BYOK providers where each family supplies their own client_id/secret (e.g. TrueLayer, EnableBanking).
      t.references :provider_family_config, null: true, foreign_key: true, type: :uuid
      t.string  :provider_key, null: false
      t.string  :auth_type, null: false
      t.jsonb   :credentials, default: {}, null: false
      t.string  :status, null: false, default: "pending"
      t.jsonb   :metadata, default: {}, null: false
      t.string  :sync_error
      t.date    :sync_start_date
      t.datetime :last_synced_at
      t.timestamps
    end
    # Non-unique: a family can have multiple bank connections per provider
    # (e.g., Monzo + Barclays both via TrueLayer = two provider_connections)
    add_index :provider_connections, [ :family_id, :provider_key ]

    create_table :provider_accounts, id: :uuid do |t|
      t.references :provider_connection, null: false, foreign_key: true, type: :uuid
      t.references :account, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string  :external_id, null: false
      t.string  :external_name
      t.string  :external_type
      t.string  :external_subtype
      t.string  :currency
      t.boolean :skipped, null: false, default: false
      t.jsonb   :raw_payload, default: {}, null: false
      t.jsonb   :raw_holdings_payload
      t.jsonb   :raw_liabilities_payload
      t.datetime :last_synced_at
      t.timestamps
    end
    add_index :provider_accounts, [ :provider_connection_id, :external_id ],
              unique: true,
              name: "index_provider_accounts_on_connection_and_external_id"
  end
end
