class AddReconciliationToEntries < ActiveRecord::Migration[7.2]
  # entries is the largest table in the app, so the indexes are built
  # concurrently and the check constraint is added unvalidated then validated
  # separately -- VALIDATE takes only SHARE UPDATE EXCLUSIVE, so neither step
  # blocks writes for the length of a full scan.
  disable_ddl_transaction!

  # Reconciliation follows the Quicken model of uncleared / cleared / reconciled,
  # but only the last state is stored.
  #
  # "Cleared" means the institution acknowledged the transaction, which is
  # exactly what entries.source and entries.external_id already record — and it
  # stays accurate on its own, because Account::ProviderImportAdapter stamps both
  # onto a manually-entered entry when a provider transaction claims it. Storing
  # a separate flag would duplicate that truth and let it drift.
  #
  # "Reconciled" means a specific statement was matched against the transaction.
  # Nothing in the schema can derive that, so it is recorded here.
  def up
    add_column :entries, :reconciled_at, :datetime, null: true

    add_reference :entries,
                  :reconciled_by_statement,
                  type: :uuid,
                  null: true,
                  index: false,
                  foreign_key: { to_table: :account_statements, on_delete: :nullify }

    # Supports "what has this statement reconciled?" when unwinding a statement,
    # and is narrow because the reconciled rows are a small slice of entries.
    add_index :entries,
              :reconciled_by_statement_id,
              where: "reconciled_by_statement_id IS NOT NULL",
              name: "index_entries_on_reconciled_by_statement",
              algorithm: :concurrently

    # Supports the per-account reconciled/unreconciled split the import review
    # screen and the account ledger both need.
    add_index :entries,
              [ :account_id, :reconciled_at ],
              where: "reconciled_at IS NOT NULL",
              name: "index_entries_on_account_and_reconciled_at",
              algorithm: :concurrently

    # An entry can be reconciled without a statement on file (marked by hand, or
    # the statement was later deleted and the FK nulled), but it can never point
    # at a statement without being reconciled.
    add_check_constraint :entries,
                         "reconciled_by_statement_id IS NULL OR reconciled_at IS NOT NULL",
                         name: "chk_entries_reconciled_at_present_when_statement_set",
                         validate: false
    validate_check_constraint :entries, name: "chk_entries_reconciled_at_present_when_statement_set"
  end

  def down
    remove_check_constraint :entries, name: "chk_entries_reconciled_at_present_when_statement_set"
    remove_index :entries, name: "index_entries_on_account_and_reconciled_at", algorithm: :concurrently
    remove_index :entries, name: "index_entries_on_reconciled_by_statement", algorithm: :concurrently
    remove_reference :entries, :reconciled_by_statement, type: :uuid, foreign_key: { to_table: :account_statements }
    remove_column :entries, :reconciled_at
  end
end
