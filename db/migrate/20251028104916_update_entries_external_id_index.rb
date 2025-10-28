class UpdateEntriesExternalIdIndex < ActiveRecord::Migration[7.2]
  def up
    # Remove the old index on [external_id, source]
    remove_index :entries, name: "index_entries_on_external_id_and_source", if_exists: true

    # Add new index on [account_id, source, external_id] with WHERE clause
    # This ensures external_id is unique per (account, source) combination
    # Allows same account to have multiple providers with separate entries
    add_index :entries, [ :account_id, :source, :external_id ],
              unique: true,
              where: "(external_id IS NOT NULL) AND (source IS NOT NULL)",
              name: "index_entries_on_account_source_and_external_id"
  end

  def down
    # Remove the new index
    remove_index :entries, name: "index_entries_on_account_source_and_external_id", if_exists: true

    # Restore the old index
    add_index :entries, [ :external_id, :source ],
              unique: true,
              where: "(external_id IS NOT NULL) AND (source IS NOT NULL)",
              name: "index_entries_on_external_id_and_source"
  end
end
