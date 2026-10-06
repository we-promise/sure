class AddUnreadLookupIndexToEntries < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Serves the per-account unread counts in the sidebar: accessible accounts,
  # transactions created after the user's read watermark.
  def change
    add_index :entries, [ :account_id, :created_at ],
              where: "entryable_type = 'Transaction'",
              name: "index_entries_on_account_id_and_created_at_transactions",
              algorithm: :concurrently
  end
end
