class ChangeBondLotsEntryFkToCascade < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :bond_lots, :entries
    add_foreign_key :bond_lots, :entries, on_delete: :cascade
  end

  def down
    remove_foreign_key :bond_lots, :entries
    add_foreign_key :bond_lots, :entries, on_delete: :nullify
  end
end
