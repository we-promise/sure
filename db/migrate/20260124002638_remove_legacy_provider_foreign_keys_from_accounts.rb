# frozen_string_literal: true

# This migration removes the legacy direct foreign key columns from the accounts table.
# These columns were superseded by the polymorphic account_providers join table which
# provides a unified approach for linking accounts to any provider type.
#
# Before this migration:
#   - accounts.plaid_account_id -> plaid_accounts.id (direct FK)
#   - accounts.simplefin_account_id -> simplefin_accounts.id (direct FK)
#
# After this migration:
#   - All provider links go through account_providers (provider_type, provider_id)
#
# Safety: This migration verifies no orphaned accounts exist before removing columns.
class RemoveLegacyProviderForeignKeysFromAccounts < ActiveRecord::Migration[7.2]
  def up
    # Safety check: Verify no accounts are linked via legacy FK without an AccountProvider
    orphaned_plaid = exec_query(<<~SQL).rows.count
      SELECT a.id FROM accounts a
      WHERE a.plaid_account_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM account_providers ap
          WHERE ap.account_id = a.id
            AND ap.provider_type = 'PlaidAccount'
            AND ap.provider_id = a.plaid_account_id
        )
    SQL

    orphaned_simplefin = exec_query(<<~SQL).rows.count
      SELECT a.id FROM accounts a
      WHERE a.simplefin_account_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM account_providers ap
          WHERE ap.account_id = a.id
            AND ap.provider_type = 'SimplefinAccount'
            AND ap.provider_id = a.simplefin_account_id
        )
    SQL

    if orphaned_plaid > 0 || orphaned_simplefin > 0
      raise "MIGRATION ABORTED: Found #{orphaned_plaid} Plaid and #{orphaned_simplefin} SimpleFIN " \
            "accounts with legacy FK but no AccountProvider. Run data backfill first."
    end

    # Remove the indexes first (if they exist), then remove the columns
    remove_index :accounts, :plaid_account_id, if_exists: true
    remove_index :accounts, :simplefin_account_id, if_exists: true

    remove_column :accounts, :plaid_account_id, :uuid
    remove_column :accounts, :simplefin_account_id, :uuid
  end

  def down
    add_column :accounts, :plaid_account_id, :uuid
    add_column :accounts, :simplefin_account_id, :uuid

    add_index :accounts, :plaid_account_id
    add_index :accounts, :simplefin_account_id

    add_foreign_key :accounts, :plaid_accounts, column: :plaid_account_id
    add_foreign_key :accounts, :simplefin_accounts, column: :simplefin_account_id

    # Note: Rolling back will NOT restore data that was in these columns.
    # The AccountProvider records remain the source of truth.
  end
end
