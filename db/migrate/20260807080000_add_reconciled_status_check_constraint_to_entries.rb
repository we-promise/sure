class AddReconciledStatusCheckConstraintToEntries < ActiveRecord::Migration[7.2]
  def change
    # The Rails enum (see Entry#reconciled_status) only guards writes that go
    # through the model. Enforce the same three-value domain in Postgres so a
    # raw SQL write, a bulk import path, or a future write path that skips
    # model validation can't leave reconciled_status outside
    # unreconciled/cleared/reconciled.
    add_check_constraint :entries,
      "reconciled_status IN ('unreconciled', 'cleared', 'reconciled')",
      name: "chk_entries_reconciled_status"
  end
end
