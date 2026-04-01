class AddUniqueIndexOnBondLotsEntryId < ActiveRecord::Migration[7.2]
  def change
    remove_index :bond_lots, :entry_id, if_exists: true
    add_index :bond_lots, :entry_id, unique: true, where: "entry_id IS NOT NULL"
  end
end
