class FixAccountProvidersIndexes < ActiveRecord::Migration[7.2]
  def change
    # Remove the overly restrictive unique index on account_id alone
    # This was preventing an account from having multiple providers
    remove_index :account_providers, name: "index_account_providers_on_account_id"

    # Add proper composite unique index to match model validation
    # This allows an account to have multiple providers, but only one of each type
    # e.g., Account can have PlaidAccount + SimplefinAccount, but not two PlaidAccounts
    add_index :account_providers, [ :account_id, :provider_type ],
              unique: true,
              name: "index_account_providers_on_account_and_provider_type"

    # Remove redundant non-unique index (cleanup)
    # Line 30 already has a unique index on the same columns
    remove_index :account_providers, name: "index_account_providers_on_provider"
  end
end
