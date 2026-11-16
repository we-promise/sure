class AddManualReconciliation < ActiveRecord::Migration[8.1]
  # Build the index without blocking writes to large entries tables.
  disable_ddl_transaction!

  def change
    add_column :entries, :reconciled_status, :string, default: "unreconciled", null: false
    add_index :entries, [ :account_id, :reconciled_status ],
      name: "index_entries_on_account_id_and_reconciled_status",
      algorithm: :concurrently
    add_check_constraint :entries,
      "reconciled_status IN ('unreconciled', 'cleared', 'reconciled')",
      name: "chk_entries_reconciled_status"

    add_column :families, :manual_reconciliation, :boolean, default: false, null: false
  end
end
