class RemoveDuplicateAccountProvidersIndex < ActiveRecord::Migration[7.2]
  def up
    # We currently have two unique indexes on the same column set (account_id, provider_type):
    #  - index_account_providers_on_account_and_provider_type (added in FixAccountProvidersIndexes)
    #  - index_account_providers_on_account_id_and_provider_type (legacy auto-generated name)
    # Drop the legacy duplicate to avoid redundant constraint checks and storage.
    if index_exists?(:account_providers, [ :account_id, :provider_type ], name: "index_account_providers_on_account_id_and_provider_type")
      remove_index :account_providers, name: "index_account_providers_on_account_id_and_provider_type"
    end
  end

  def down
    # Recreate the legacy index if it doesn't exist (kept reversible for safety).
    unless index_exists?(:account_providers, [ :account_id, :provider_type ], name: "index_account_providers_on_account_id_and_provider_type")
      add_index :account_providers, [ :account_id, :provider_type ], unique: true, name: "index_account_providers_on_account_id_and_provider_type"
    end
  end
end
