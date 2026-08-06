class AddReconciledStatusToEntries < ActiveRecord::Migration[7.2]
  def change
    # Bluecoins-style manual reconciliation status. Independent of bank-sync
    # "pending" status — this lets a user confirm a manually-entered (or
    # synced) transaction against a paper/PDF bank statement, the same way
    # you'd tick off a checkbook register line by line.
    #
    #   unreconciled - default. Entered, but not yet checked against a statement.
    #   cleared      - confirmed to exist on the bank/card statement, but the
    #                  statement period hasn't been fully reconciled yet.
    #   reconciled   - statement period fully reconciled; this line is locked in.
    add_column :entries, :reconciled_status, :string, default: "unreconciled", null: false
    add_index :entries, :reconciled_status

    # Composite index for the common "reconcile this account" query:
    # unreconciled/cleared entries for one account, ordered by date.
    add_index :entries, [ :account_id, :reconciled_status ], name: "index_entries_on_account_id_and_reconciled_status"
  end
end
