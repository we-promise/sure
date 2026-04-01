class AddOnDeleteToBondLotsForeignKeys < ActiveRecord::Migration[7.2]
  def change
    remove_foreign_key :bond_lots, :bonds
    add_foreign_key :bond_lots, :bonds, on_delete: :cascade

    # Intentionally nullify (not cascade): bond_lot is the primary domain object;
    # deleting an entry at DB level should only clear the reference, not destroy the lot.
    # Rails-layer deletion goes through Entry's dependent: :destroy which handles lot cleanup.
    remove_foreign_key :bond_lots, :entries
    add_foreign_key :bond_lots, :entries, on_delete: :nullify
  end
end
