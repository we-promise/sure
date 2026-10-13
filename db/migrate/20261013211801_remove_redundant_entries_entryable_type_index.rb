class RemoveRedundantEntriesEntryableTypeIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_entries_on_entryable_type"
  COVERING_INDEX_NAME = "index_entries_on_entryable"

  # The composite (entryable_type, entryable_id) index from the previous
  # migration covers lookups by entryable_type alone. Keep the old index
  # unless that one is in place and valid.
  def up
    unless select_value("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass(#{connection.quote(COVERING_INDEX_NAME)})") == true
      raise "#{COVERING_INDEX_NAME} is missing or invalid; not dropping #{INDEX_NAME}"
    end

    remove_index :entries, name: INDEX_NAME, if_exists: true, algorithm: :concurrently
  end

  def down
    add_index :entries, :entryable_type,
              name: INDEX_NAME,
              if_not_exists: true,
              algorithm: :concurrently
  end
end
