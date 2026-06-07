class TightenTransferMatchLookupIndex < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    remove_index :entries,
                 name: "index_entries_on_transfer_match_lookup",
                 if_exists: true,
                 algorithm: :concurrently

    add_index :entries,
              [ :currency, :amount, :date, :account_id ],
              name: "index_entries_on_transfer_match_lookup",
              where: "entryable_type = 'Transaction' AND excluded = false",
              algorithm: :concurrently
  end
end
