class AddPurchaseFieldsToBondLots < ActiveRecord::Migration[7.2]
  def change
    add_column :bond_lots, :subtype, :string, null: false, default: "other"
    add_column :bond_lots, :rate_type, :string
    add_column :bond_lots, :coupon_frequency, :string
    add_reference :bond_lots, :entry, type: :uuid, foreign_key: true

    execute <<~SQL
      UPDATE bond_lots
      SET rate_type = COALESCE(rate_type, 'fixed'),
          coupon_frequency = COALESCE(coupon_frequency, 'at_maturity')
      WHERE subtype NOT IN ('eod', 'rod')
    SQL

    add_index :bond_lots, :subtype

    # Enforce that subtype is set at the database level.
    add_check_constraint :bond_lots, "subtype IS NOT NULL", name: "check_bond_lots_subtype_not_null"
    add_check_constraint :bond_lots,
                         "subtype IN ('eod', 'rod') OR (rate_type IS NOT NULL AND coupon_frequency IS NOT NULL)",
                         name: "check_bond_lots_non_inflation_rate_fields_present"
  end
end
