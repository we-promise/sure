class AddPurchaseFieldsToBondLots < ActiveRecord::Migration[7.2]
  def change
    add_column :bond_lots, :subtype, :string, null: false, default: "other"
    add_column :bond_lots, :rate_type, :string
    add_column :bond_lots, :coupon_frequency, :string
    add_reference :bond_lots, :entry, type: :uuid, foreign_key: true

    add_index :bond_lots, :subtype

    # Enforce that subtype is set at the database level.
    add_check_constraint :bond_lots, "subtype IS NOT NULL", name: "check_bond_lots_subtype_not_null"
  end
end
