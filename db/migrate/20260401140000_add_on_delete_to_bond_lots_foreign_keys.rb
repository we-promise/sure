class AddOnDeleteToBondLotsForeignKeys < ActiveRecord::Migration[7.2]
  def change
    remove_foreign_key :bond_lots, :bonds
    add_foreign_key :bond_lots, :bonds, on_delete: :cascade

    remove_foreign_key :bond_lots, :entries
    add_foreign_key :bond_lots, :entries, on_delete: :nullify
  end
end
