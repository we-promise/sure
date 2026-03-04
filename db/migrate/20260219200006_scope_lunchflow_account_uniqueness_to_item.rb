# frozen_string_literal: true

# NEW constraint: add per-item unique index on lunchflow_accounts. Unlike Plaid/Snaptrade,
# there was no prior unique index—this can fail if existing data has duplicate
# (lunchflow_item_id, account_id) pairs. See: https://github.com/we-promise/sure/issues/740
class ScopeLunchflowAccountUniquenessToItem < ActiveRecord::Migration[7.2]
  def up
    return if index_exists?(:lunchflow_accounts, [ :lunchflow_item_id, :account_id ], unique: true, name: "index_lunchflow_accounts_on_item_and_account_id")

    if execute("SELECT 1 FROM lunchflow_accounts WHERE account_id IS NOT NULL GROUP BY lunchflow_item_id, account_id HAVING COUNT(*) > 1 LIMIT 1").any?
      raise ActiveRecord::Migration::IrreversibleMigration,
            "Duplicate (lunchflow_item_id, account_id) pairs exist in lunchflow_accounts. Resolve duplicates before running this migration."
    end

    add_index :lunchflow_accounts,
              [ :lunchflow_item_id, :account_id ],
              unique: true,
              name: "index_lunchflow_accounts_on_item_and_account_id",
              where: "account_id IS NOT NULL"
  end

  def down
    remove_index :lunchflow_accounts, name: "index_lunchflow_accounts_on_item_and_account_id", if_exists: true
  end
end
