class AddEntriesEntryableIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_entries_on_entryable"

  # `has_one :entry, as: :entryable` looks entries up by
  # (entryable_type, entryable_id). Without this index every
  # `transaction.entry`, entry preload and `touch: true` scans all entries
  # of that type. The composite index also covers the old single-column one.
  def up
    # index_exists? alone isn't enough: an interrupted CREATE INDEX
    # CONCURRENTLY leaves an INVALID index behind, which index_exists? still
    # reports. A valid index is kept, so rerunning is a no-op; an invalid
    # leftover is dropped and rebuilt.
    return if valid_index_exists?

    execute "DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}"

    add_index :entries, [ :entryable_type, :entryable_id ],
              name: INDEX_NAME,
              algorithm: :concurrently
  end

  def down
    remove_index :entries, name: INDEX_NAME, if_exists: true, algorithm: :concurrently
  end

  private
    def valid_index_exists?
      select_value(<<~SQL.squish) == true
        SELECT indisvalid FROM pg_index
        JOIN pg_class ON pg_class.oid = pg_index.indexrelid
        WHERE pg_class.relname = '#{INDEX_NAME}'
      SQL
    end
end
