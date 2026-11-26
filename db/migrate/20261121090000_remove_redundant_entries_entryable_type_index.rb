class RemoveRedundantEntriesEntryableTypeIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_entries_on_entryable_type"
  COVERING_INDEX_NAME = "index_entries_on_entryable_type_and_entryable_id"
  # Earlier revisions of this change built the same composite index under this
  # name. Databases that ran them would otherwise keep two identical indexes.
  DUPLICATE_INDEX_NAME = "index_entries_on_entryable"

  # The composite (entryable_type, entryable_id) index covers lookups by
  # entryable_type alone. Keep the old index unless that one is in place and
  # valid.
  def up
    unless valid_index_exists?(COVERING_INDEX_NAME)
      raise "#{COVERING_INDEX_NAME} is missing or invalid; not dropping #{INDEX_NAME}"
    end

    remove_index :entries, name: INDEX_NAME, if_exists: true, algorithm: :concurrently
    remove_index :entries, name: DUPLICATE_INDEX_NAME, if_exists: true, algorithm: :concurrently
  end

  # Keep a valid index, rebuild an INVALID leftover from an interrupted
  # concurrent build instead of skipping it. The duplicate isn't restored.
  def down
    return if valid_index_exists?(INDEX_NAME)

    execute "DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}"

    add_index :entries, :entryable_type,
              name: INDEX_NAME,
              algorithm: :concurrently
  end

  private
    def valid_index_exists?(name)
      select_value(<<~SQL.squish) == true
        SELECT indisvalid FROM pg_index
        WHERE indexrelid = to_regclass(#{connection.quote(name)})
      SQL
    end
end
