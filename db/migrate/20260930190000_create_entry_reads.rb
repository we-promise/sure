class CreateEntryReads < ActiveRecord::Migration[8.1]
  def change
    # One row per (user, entry) the user has seen in a transaction list. Entries
    # are deleted and re-ingested during syncs, so cascade instead of blocking.
    create_table :entry_reads, id: :uuid do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: false
      t.references :entry, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.datetime :created_at, null: false
    end

    add_index :entry_reads, [ :user_id, :entry_id ], unique: true

    # Everything created before this moment counts as read for the user. The
    # database default stamps existing users with the migration time (so the
    # existing history never shows as unread) and new users with their signup.
    add_column :users, :transactions_read_before, :datetime,
               null: false, default: -> { "CURRENT_TIMESTAMP" }
  end
end
