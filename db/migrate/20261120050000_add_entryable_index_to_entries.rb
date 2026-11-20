class AddEntryableIndexToEntries < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Every lookup of an entry from its transaction, trade or valuation filters on
  # both columns, and the entryable_type index alone has a handful of values,
  # so each one scanned that type's entries across every family. The new index
  # starts with entryable_type, which makes the single-column one redundant.
  def change
    add_index :entries, [ :entryable_type, :entryable_id ], algorithm: :concurrently, if_not_exists: true
    remove_index :entries, [ :entryable_type ], name: "index_entries_on_entryable_type", algorithm: :concurrently, if_exists: true
  end
end
