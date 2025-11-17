# frozen_string_literal: true

class AddCascadeOnAccountDeletes < ActiveRecord::Migration[7.2]
  def up
    # Clean up orphaned rows before re-adding foreign keys with cascade
    suppress_messages do
      if table_exists?(:account_providers)
        execute <<~SQL
          DELETE FROM account_providers
          WHERE account_id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM accounts WHERE accounts.id = account_providers.account_id);
        SQL
      end
      if table_exists?(:holdings)
        execute <<~SQL
          DELETE FROM holdings
          WHERE account_id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM accounts WHERE accounts.id = holdings.account_id);
        SQL
      end
      if table_exists?(:entries)
        execute <<~SQL
          DELETE FROM entries
          WHERE account_id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM accounts WHERE accounts.id = entries.account_id);
        SQL
      end
    end

    # Entries -> Accounts (account_id)
    if foreign_key_exists?(:entries, :accounts)
      # Replace existing FK with ON DELETE CASCADE
      remove_foreign_key :entries, :accounts
    end
    add_foreign_key :entries, :accounts, column: :account_id, on_delete: :cascade unless foreign_key_exists?(:entries, :accounts)

    # Holdings -> Accounts (account_id)
    if table_exists?(:holdings)
      if foreign_key_exists?(:holdings, :accounts)
        remove_foreign_key :holdings, :accounts
      end
      add_foreign_key :holdings, :accounts, column: :account_id, on_delete: :cascade unless foreign_key_exists?(:holdings, :accounts)
    end

    # AccountProviders -> Accounts (account_id) — typically we want provider links gone if account is removed
    if table_exists?(:account_providers)
      if foreign_key_exists?(:account_providers, :accounts)
        remove_foreign_key :account_providers, :accounts
      end
      add_foreign_key :account_providers, :accounts, column: :account_id, on_delete: :cascade unless foreign_key_exists?(:account_providers, :accounts)
    end
  end

  def down
    # Revert cascades to simple FK without cascade (best-effort)
    if foreign_key_exists?(:entries, :accounts)
      remove_foreign_key :entries, :accounts
      add_foreign_key :entries, :accounts, column: :account_id
    end

    if table_exists?(:holdings) && foreign_key_exists?(:holdings, :accounts)
      remove_foreign_key :holdings, :accounts
      add_foreign_key :holdings, :accounts, column: :account_id
    end

    if table_exists?(:account_providers) && foreign_key_exists?(:account_providers, :accounts)
      remove_foreign_key :account_providers, :accounts
      add_foreign_key :account_providers, :accounts, column: :account_id
    end
  end
end
