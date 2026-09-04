class AddIdempotencyKeyToEntries < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  INDEX_NAME = "index_entries_on_account_and_idempotency_key"

  def up
    add_column :entries, :idempotency_key, :string unless column_exists?(:entries, :idempotency_key)

    # index_exists? alone isn't enough: CREATE INDEX CONCURRENTLY leaves an
    # INVALID index behind if it's interrupted (e.g. a deploy killed
    # mid-build), and index_exists? still reports that catalog entry as
    # present - short-circuiting here would record this migration as
    # applied while the constraint is actually missing/broken.
    return if valid_index_exists?

    # Deliberately a separate column from external_id/source: those two are
    # provider-linkage fields (Entry#linked? = external_id.present?), and
    # reusing them for a web-form anti-double-submit token would make a
    # perfectly ordinary manual entry look provider-synced - disabling its
    # date/nature/amount/currency fields in the editor, and making it
    # invisible to future provider dedup matching (which filters to
    # external_id: nil). idempotency_key has no such meaning anywhere else,
    # so it's safe to set on manual entries without side effects.
    execute "DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}"

    add_index :entries, [ :account_id, :idempotency_key ],
              unique: true,
              where: "(idempotency_key IS NOT NULL)",
              name: INDEX_NAME,
              algorithm: :concurrently
  end

  def down
    remove_index :entries, name: INDEX_NAME, if_exists: true, algorithm: :concurrently
    remove_column :entries, :idempotency_key, if_exists: true
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
