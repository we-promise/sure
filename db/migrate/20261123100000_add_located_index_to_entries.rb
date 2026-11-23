class AddLocatedIndexToEntries < ActiveRecord::Migration[8.1]
  def change
    add_index :entries, [ :account_id, :date ], where: "location_lat IS NOT NULL", name: "index_entries_on_located"
  end
end
