class AddTransferMatchLookupIndexToEntries < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_index :entries,
              [ :currency, :amount, :date, :account_id ],
              name: "index_entries_on_transfer_match_lookup",
              where: "entryable_type = 'Transaction'",
              algorithm: :concurrently
  end
end
