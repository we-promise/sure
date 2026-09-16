class AddSharedAccountProviderLinks < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :account_providers, :external_account_id, :uuid
    add_column :account_providers, :family_id, :uuid
    add_column :account_providers, :provider_key, :string
    change_column_null :account_providers, :provider_id, true
    change_column_null :account_providers, :provider_type, true
    add_index :account_providers, :external_account_id, unique: true, algorithm: :concurrently
    add_index :account_providers, [ :account_id, :provider_key ], unique: true, algorithm: :concurrently
    add_index :account_providers, [ :id, :account_id, :family_id ], unique: true,
      name: "idx_account_providers_identity_tenant", algorithm: :concurrently
    add_index :entries, [ :id, :account_id ], unique: true,
      name: "idx_entries_identity_account", algorithm: :concurrently
    add_index :holdings, [ :id, :account_id ], unique: true,
      name: "idx_holdings_identity_account", algorithm: :concurrently
    add_index :accounts, [ :id, :family_id ], unique: true,
      name: "idx_accounts_identity_tenant", algorithm: :concurrently
    add_foreign_key :account_providers, :accounts,
      column: [ :account_id, :family_id ], primary_key: [ :id, :family_id ], validate: false
    add_foreign_key :account_providers, :external_accounts,
      column: [ :external_account_id, :family_id, :provider_key ], primary_key: [ :id, :family_id, :provider_key ], validate: false
    add_check_constraint :account_providers,
      "(provider_id IS NULL) = (provider_type IS NULL)", name: "account_providers_legacy_pair", validate: false
    add_check_constraint :account_providers,
      "provider_id IS NOT NULL OR external_account_id IS NOT NULL", name: "account_providers_has_source", validate: false
    add_check_constraint :account_providers,
      "external_account_id IS NULL OR (family_id IS NOT NULL AND provider_key IS NOT NULL)",
      name: "account_providers_shared_identity", validate: false
    validate_foreign_key :account_providers, :accounts, column: [ :account_id, :family_id ]
    validate_foreign_key :account_providers, :external_accounts
    %w[account_providers_legacy_pair account_providers_has_source account_providers_shared_identity].each do |name|
      validate_check_constraint :account_providers, name: name
    end
  end

  def down
    if select_value("SELECT 1 FROM account_providers WHERE provider_id IS NULL LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "Restore legacy provider links before removing shared links"
    end
    remove_check_constraint :account_providers, name: "account_providers_shared_identity"
    remove_check_constraint :account_providers, name: "account_providers_has_source"
    remove_check_constraint :account_providers, name: "account_providers_legacy_pair"
    remove_foreign_key :account_providers, :external_accounts
    remove_foreign_key :account_providers, column: [ :account_id, :family_id ]
    remove_index :entries, name: "idx_entries_identity_account", algorithm: :concurrently
    remove_index :holdings, name: "idx_holdings_identity_account", algorithm: :concurrently
    remove_index :accounts, name: "idx_accounts_identity_tenant", algorithm: :concurrently
    remove_index :account_providers, name: "idx_account_providers_identity_tenant", algorithm: :concurrently
    remove_column :account_providers, :provider_key
    remove_column :account_providers, :family_id
    remove_column :account_providers, :external_account_id
    change_column_null :account_providers, :provider_id, false
    change_column_null :account_providers, :provider_type, false
  end
end
