class ChangeBondLotsEntryFkToCascade < ActiveRecord::Migration[7.2]
  def change
    remove_foreign_key :bond_lots, :entries
    add_foreign_key :bond_lots, :entries, on_delete: :cascade
  end
end
