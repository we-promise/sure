class DropLegacyPlaidTables < ActiveRecord::Migration[7.2]
  def up
    # accounts.plaid_account_id had a FK to plaid_accounts.id; remove FK first.
    if foreign_key_exists?(:accounts, :plaid_accounts)
      remove_foreign_key :accounts, :plaid_accounts
    end
    if column_exists?(:accounts, :plaid_account_id)
      remove_index :accounts, :plaid_account_id if index_exists?(:accounts, :plaid_account_id)
      remove_column :accounts, :plaid_account_id
    end

    drop_table :plaid_accounts if table_exists?(:plaid_accounts)
    drop_table :plaid_items if table_exists?(:plaid_items)
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "plaid_items / plaid_accounts cannot be recreated. Restore from backup if rollback is required."
  end
end
