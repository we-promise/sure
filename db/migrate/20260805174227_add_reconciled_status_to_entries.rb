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
    #
    # Indexing is a separate migration (see AddReconciledStatusIndexToEntries)
    # so it can run with algorithm: :concurrently — entries is one of the
    # largest tables here, and a plain add_index takes a write-blocking lock
    # for the duration of the build on self-hosted instances with a lot of
    # history.
    add_column :entries, :reconciled_status, :string, default: "unreconciled", null: false
  end
end
