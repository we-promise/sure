class FixBondLotsNonInflationCheckConstraint < ActiveRecord::Migration[7.2]
  def up
    remove_check_constraint :bond_lots, name: "check_bond_lots_non_inflation_rate_fields_present"
    add_check_constraint :bond_lots,
                         "(subtype IN ('inflation_linked')) OR (rate_type IS NOT NULL AND coupon_frequency IS NOT NULL)",
                         name: "check_bond_lots_non_inflation_rate_fields_present"
  end

  def down
    remove_check_constraint :bond_lots, name: "check_bond_lots_non_inflation_rate_fields_present"
    add_check_constraint :bond_lots,
                         "(subtype IN ('inflation_linked')) OR (rate_type IS NOT NULL AND coupon_frequency IS NOT NULL)",
                         name: "check_bond_lots_non_inflation_rate_fields_present"
  end
end
