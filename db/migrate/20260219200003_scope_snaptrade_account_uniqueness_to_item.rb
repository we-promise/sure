# frozen_string_literal: true

# Scope snaptrade_accounts uniqueness to snaptrade_item so the same external
# account can be linked in multiple families. See: https://github.com/we-promise/sure/issues/740
class ScopeSnaptradeAccountUniquenessToItem < ActiveRecord::Migration[7.2]
  def up
    remove_index :snaptrade_accounts, name: "index_snaptrade_accounts_on_account_id", if_exists: true
    remove_index :snaptrade_accounts, name: "index_snaptrade_accounts_on_snaptrade_account_id", if_exists: true

    unless index_exists?(:snaptrade_accounts, [ :snaptrade_item_id, :account_id ], unique: true, name: "index_snaptrade_accounts_on_item_and_account_id")
      add_index :snaptrade_accounts,
                [ :snaptrade_item_id, :account_id ],
                unique: true,
                name: "index_snaptrade_accounts_on_item_and_account_id",
                where: "account_id IS NOT NULL"
    end
    unless index_exists?(:snaptrade_accounts, [ :snaptrade_item_id, :snaptrade_account_id ], unique: true, name: "index_snaptrade_accounts_on_item_and_snaptrade_account_id")
      add_index :snaptrade_accounts,
                [ :snaptrade_item_id, :snaptrade_account_id ],
                unique: true,
                name: "index_snaptrade_accounts_on_item_and_snaptrade_account_id",
                where: "snaptrade_account_id IS NOT NULL"
    end
  end

  def down
    if execute("SELECT 1 FROM snaptrade_accounts WHERE account_id IS NOT NULL GROUP BY account_id HAVING COUNT(DISTINCT snaptrade_item_id) > 1 LIMIT 1").any? ||
        execute("SELECT 1 FROM snaptrade_accounts WHERE snaptrade_account_id IS NOT NULL GROUP BY snaptrade_account_id HAVING COUNT(DISTINCT snaptrade_item_id) > 1 LIMIT 1").any?
      raise ActiveRecord::IrreversibleMigration,
            "Cannot rollback: cross-item duplicates exist in snaptrade_accounts. Remove duplicates first."
    end

    remove_index :snaptrade_accounts, name: "index_snaptrade_accounts_on_item_and_account_id", if_exists: true
    remove_index :snaptrade_accounts, name: "index_snaptrade_accounts_on_item_and_snaptrade_account_id", if_exists: true
    unless index_exists?(:snaptrade_accounts, :account_id, name: "index_snaptrade_accounts_on_account_id")
      add_index :snaptrade_accounts, :account_id,
                name: "index_snaptrade_accounts_on_account_id",
                unique: true,
                where: "account_id IS NOT NULL"
    end
    unless index_exists?(:snaptrade_accounts, :snaptrade_account_id, name: "index_snaptrade_accounts_on_snaptrade_account_id")
      add_index :snaptrade_accounts, :snaptrade_account_id,
                name: "index_snaptrade_accounts_on_snaptrade_account_id",
                unique: true,
                where: "snaptrade_account_id IS NOT NULL"
    end
  end
end
