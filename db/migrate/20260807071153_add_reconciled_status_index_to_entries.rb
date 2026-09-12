class AddReconciledStatusIndexToEntries < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    # Composite index for the common "reconcile this account" query:
    # unreconciled/cleared entries for one account, ordered by date. This is
    # the only index reconciliation queries actually need — every place that
    # filters by reconciled_status also filters by account (either a single
    # account's register, or Transaction::Search's manual-accounts scope), so
    # a standalone index on reconciled_status alone (3 distinct values, weak
    # selectivity) would just be dead weight.
    #
    # algorithm: :concurrently avoids taking a write-blocking lock on entries
    # for the duration of the build — worth it since entries is one of the
    # largest tables here and self-hosted instances can have a lot of history.
    add_index :entries, [ :account_id, :reconciled_status ],
      name: "index_entries_on_account_id_and_reconciled_status",
      algorithm: :concurrently
  end
end
