class AddLocatedIndexToEntries < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # entries is the largest table in the app, so the index is built concurrently.
  def change
    add_index :entries, [ :account_id, :date ], where: "location_lat IS NOT NULL",
              name: "index_entries_on_located", algorithm: :concurrently, if_not_exists: true
  end
end
