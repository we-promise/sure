# frozen_string_literal: true

# Scope provider account uniqueness to the connection (item) so the same external
# account can be linked in multiple families or connections, each with its own
# independent ledger (transactions, categorizations, tags). Covers all provider
# account types; Mercury and SimpleFIN already used this pattern.
# See: https://github.com/we-promise/sure/issues/740
class ScopeAllProviderAccountUniquenessToItem < ActiveRecord::Migration[7.2]
  def up
    scope_plaid_accounts
    scope_indexa_capital_accounts
    scope_snaptrade_accounts
    add_per_item_unique_coinbase_accounts
    add_per_item_unique_enable_banking_accounts
    add_per_item_unique_lunchflow_accounts
  end

  def down
    revert_plaid_accounts
    revert_indexa_capital_accounts
    revert_snaptrade_accounts
    revert_coinbase_accounts
    revert_enable_banking_accounts
    revert_lunchflow_accounts
  end

  private

    def scope_plaid_accounts
      remove_index :plaid_accounts, name: "index_plaid_accounts_on_plaid_id", if_exists: true
      return if index_exists?(:plaid_accounts, [ :plaid_item_id, :plaid_id ], unique: true, name: "index_plaid_accounts_on_item_and_plaid_id")

      add_index :plaid_accounts,
                [ :plaid_item_id, :plaid_id ],
                unique: true,
                name: "index_plaid_accounts_on_item_and_plaid_id"
    end

    def revert_plaid_accounts
      remove_index :plaid_accounts, name: "index_plaid_accounts_on_item_and_plaid_id", if_exists: true
      return if index_exists?(:plaid_accounts, :plaid_id, name: "index_plaid_accounts_on_plaid_id")

      add_index :plaid_accounts, :plaid_id, name: "index_plaid_accounts_on_plaid_id", unique: true
    end

    def scope_indexa_capital_accounts
      remove_index :indexa_capital_accounts, name: "index_indexa_capital_accounts_on_indexa_capital_account_id", if_exists: true
      return if index_exists?(:indexa_capital_accounts, [ :indexa_capital_item_id, :indexa_capital_account_id ], unique: true, name: "index_indexa_capital_accounts_on_item_and_account_id")

      add_index :indexa_capital_accounts,
                [ :indexa_capital_item_id, :indexa_capital_account_id ],
                unique: true,
                name: "index_indexa_capital_accounts_on_item_and_account_id",
                where: "indexa_capital_account_id IS NOT NULL"
    end

    def revert_indexa_capital_accounts
      remove_index :indexa_capital_accounts, name: "index_indexa_capital_accounts_on_item_and_account_id", if_exists: true
      return if index_exists?(:indexa_capital_accounts, :indexa_capital_account_id, name: "index_indexa_capital_accounts_on_indexa_capital_account_id")

      add_index :indexa_capital_accounts, :indexa_capital_account_id, name: "index_indexa_capital_accounts_on_indexa_capital_account_id", unique: true
    end

    def scope_snaptrade_accounts
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

    def revert_snaptrade_accounts
      remove_index :snaptrade_accounts, name: "index_snaptrade_accounts_on_item_and_account_id", if_exists: true
      remove_index :snaptrade_accounts, name: "index_snaptrade_accounts_on_item_and_snaptrade_account_id", if_exists: true
      add_index :snaptrade_accounts, :account_id, name: "index_snaptrade_accounts_on_account_id", unique: true unless index_exists?(:snaptrade_accounts, :account_id, name: "index_snaptrade_accounts_on_account_id")
      add_index :snaptrade_accounts, :snaptrade_account_id, name: "index_snaptrade_accounts_on_snaptrade_account_id", unique: true unless index_exists?(:snaptrade_accounts, :snaptrade_account_id, name: "index_snaptrade_accounts_on_snaptrade_account_id")
    end

    def add_per_item_unique_coinbase_accounts
      return if index_exists?(:coinbase_accounts, [ :coinbase_item_id, :account_id ], unique: true, name: "index_coinbase_accounts_on_item_and_account_id")

      add_index :coinbase_accounts,
                [ :coinbase_item_id, :account_id ],
                unique: true,
                name: "index_coinbase_accounts_on_item_and_account_id",
                where: "account_id IS NOT NULL"
    end

    def revert_coinbase_accounts
      remove_index :coinbase_accounts, name: "index_coinbase_accounts_on_item_and_account_id", if_exists: true
    end

    def add_per_item_unique_enable_banking_accounts
      return if index_exists?(:enable_banking_accounts, [ :enable_banking_item_id, :account_id ], unique: true, name: "index_enable_banking_accounts_on_item_and_account_id")

      add_index :enable_banking_accounts,
                [ :enable_banking_item_id, :account_id ],
                unique: true,
                name: "index_enable_banking_accounts_on_item_and_account_id",
                where: "account_id IS NOT NULL"
    end

    def revert_enable_banking_accounts
      remove_index :enable_banking_accounts, name: "index_enable_banking_accounts_on_item_and_account_id", if_exists: true
    end

    def add_per_item_unique_lunchflow_accounts
      return if index_exists?(:lunchflow_accounts, [ :lunchflow_item_id, :account_id ], unique: true, name: "index_lunchflow_accounts_on_item_and_account_id")

      add_index :lunchflow_accounts,
                [ :lunchflow_item_id, :account_id ],
                unique: true,
                name: "index_lunchflow_accounts_on_item_and_account_id",
                where: "account_id IS NOT NULL"
    end

    def revert_lunchflow_accounts
      remove_index :lunchflow_accounts, name: "index_lunchflow_accounts_on_item_and_account_id", if_exists: true
    end
end
