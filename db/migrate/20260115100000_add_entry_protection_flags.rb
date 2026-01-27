class AddEntryProtectionFlags < ActiveRecord::Migration[7.2]
  def change
    # user_modified: Set when user manually edits any field on an entry.
    # Prevents provider sync from overwriting user's intentional changes.
    # Does NOT prevent user from editing - only protects from automated overwrites.
    add_column :entries, :user_modified, :boolean, default: false, null: false

    # import_locked: Set when entry is created via CSV/manual import.
    # Prevents provider sync from overwriting imported data.
    # Does NOT prevent user from editing - only protects from automated overwrites.
    add_column :entries, :import_locked, :boolean, default: false, null: false

    # Partial indexes for efficient queries when filtering protected entries
    add_index :entries, :user_modified, where: "user_modified = true", name: "index_entries_on_user_modified_true"
    add_index :entries, :import_locked, where: "import_locked = true", name: "index_entries_on_import_locked_true"
  end
end
