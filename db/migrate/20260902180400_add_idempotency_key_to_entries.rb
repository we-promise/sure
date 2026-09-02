class AddIdempotencyKeyToEntries < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def up
    add_column :entries, :idempotency_key, :string unless column_exists?(:entries, :idempotency_key)

    return if index_exists?(:entries, [ :account_id, :idempotency_key ], unique: true, name: "index_entries_on_account_and_idempotency_key")

    # Deliberately a separate column from external_id/source: those two are
    # provider-linkage fields (Entry#linked? = external_id.present?), and
    # reusing them for a web-form anti-double-submit token would make a
    # perfectly ordinary manual entry look provider-synced - disabling its
    # date/nature/amount/currency fields in the editor, and making it
    # invisible to future provider dedup matching (which filters to
    # external_id: nil). idempotency_key has no such meaning anywhere else,
    # so it's safe to set on manual entries without side effects.
    execute "DROP INDEX CONCURRENTLY IF EXISTS index_entries_on_account_and_idempotency_key"

    add_index :entries, [ :account_id, :idempotency_key ],
              unique: true,
              where: "(idempotency_key IS NOT NULL)",
              name: "index_entries_on_account_and_idempotency_key",
              algorithm: :concurrently
  end

  def down
    remove_index :entries, name: "index_entries_on_account_and_idempotency_key", if_exists: true
    remove_column :entries, :idempotency_key, if_exists: true
  end
end
