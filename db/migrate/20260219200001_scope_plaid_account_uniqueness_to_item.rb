# frozen_string_literal: true

# Scope plaid_accounts uniqueness to plaid_item so the same external account
# can be linked in multiple families. See: https://github.com/we-promise/sure/issues/740
class ScopePlaidAccountUniquenessToItem < ActiveRecord::Migration[7.2]
  def up
    remove_index :plaid_accounts, name: "index_plaid_accounts_on_plaid_id", if_exists: true
    return if index_exists?(:plaid_accounts, [ :plaid_item_id, :plaid_id ], unique: true, name: "index_plaid_accounts_on_item_and_plaid_id")

    add_index :plaid_accounts,
              [ :plaid_item_id, :plaid_id ],
              unique: true,
              name: "index_plaid_accounts_on_item_and_plaid_id"
  end

  def down
    if execute("SELECT 1 FROM plaid_accounts WHERE plaid_id IS NOT NULL GROUP BY plaid_id HAVING COUNT(DISTINCT plaid_item_id) > 1 LIMIT 1").any?
      raise ActiveRecord::IrreversibleMigration,
            "Cannot rollback: cross-item duplicates exist in plaid_accounts. Remove duplicates first."
    end

    remove_index :plaid_accounts, name: "index_plaid_accounts_on_item_and_plaid_id", if_exists: true
    return if index_exists?(:plaid_accounts, :plaid_id, name: "index_plaid_accounts_on_plaid_id")

    add_index :plaid_accounts, :plaid_id, name: "index_plaid_accounts_on_plaid_id", unique: true
  end
end
