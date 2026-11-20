class AddCounterpartyToTransactions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    # Only the last 4 characters of a counterparty's account identifiers are
    # kept, for display. The full IBAN is matched against the family's own
    # accounts at import and then dropped.
    add_column :transactions, :counterparty_iban_last4, :string, if_not_exists: true
    add_column :transactions, :counterparty_reference_last4, :string, if_not_exists: true
    add_column :transactions, :counterparty_own_account_id, :uuid, if_not_exists: true
    add_index :transactions, :counterparty_own_account_id, algorithm: :concurrently, if_not_exists: true
    # Added unvalidated, then validated, so the check of existing rows does
    # not block writes to transactions.
    add_foreign_key :transactions, :accounts, column: :counterparty_own_account_id, on_delete: :nullify,
      validate: false, if_not_exists: true
    validate_foreign_key :transactions, :accounts, column: :counterparty_own_account_id
  end

  def down
    remove_column :transactions, :counterparty_own_account_id, if_exists: true
    remove_column :transactions, :counterparty_reference_last4, if_exists: true
    remove_column :transactions, :counterparty_iban_last4, if_exists: true
  end
end
