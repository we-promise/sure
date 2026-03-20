# frozen_string_literal: true

# Scope indexa_capital_accounts uniqueness to indexa_capital_item so the same
# external account can be linked in multiple families. See: https://github.com/we-promise/sure/issues/740
class ScopeIndexaCapitalAccountUniquenessToItem < ActiveRecord::Migration[7.2]
  def up
    remove_index :indexa_capital_accounts, name: "index_indexa_capital_accounts_on_indexa_capital_account_id", if_exists: true
    return if index_exists?(:indexa_capital_accounts, [ :indexa_capital_item_id, :indexa_capital_account_id ], unique: true, name: "index_indexa_capital_accounts_on_item_and_account_id")

    add_index :indexa_capital_accounts,
              [ :indexa_capital_item_id, :indexa_capital_account_id ],
              unique: true,
              name: "index_indexa_capital_accounts_on_item_and_account_id",
              where: "indexa_capital_account_id IS NOT NULL"
  end

  def down
    if execute("SELECT 1 FROM indexa_capital_accounts WHERE indexa_capital_account_id IS NOT NULL GROUP BY indexa_capital_account_id HAVING COUNT(DISTINCT indexa_capital_item_id) > 1 LIMIT 1").any?
      raise ActiveRecord::IrreversibleMigration,
            "Cannot rollback: cross-item duplicates exist in indexa_capital_accounts. Remove duplicates first."
    end

    remove_index :indexa_capital_accounts, name: "index_indexa_capital_accounts_on_item_and_account_id", if_exists: true
    return if index_exists?(:indexa_capital_accounts, :indexa_capital_account_id, name: "index_indexa_capital_accounts_on_indexa_capital_account_id")

    add_index :indexa_capital_accounts, :indexa_capital_account_id,
              name: "index_indexa_capital_accounts_on_indexa_capital_account_id",
              unique: true,
              where: "indexa_capital_account_id IS NOT NULL"
  end
end
