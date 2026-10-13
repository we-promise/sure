class RemoveRedundantEntriesEntryableTypeIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_entries_on_entryable_type"

  # The composite (entryable_type, entryable_id) index from the previous
  # migration covers lookups by entryable_type alone.
  def up
    remove_index :entries, name: INDEX_NAME, if_exists: true, algorithm: :concurrently
  end

  def down
    add_index :entries, :entryable_type,
              name: INDEX_NAME,
              if_not_exists: true,
              algorithm: :concurrently
  end
end
