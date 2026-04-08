class FixBondLotsNonInflationCheckConstraint < ActiveRecord::Migration[7.2]
  def up
    if check_constraint_exists?(:bond_lots, name: "check_bond_lots_non_inflation_rate_fields_present")
      remove_check_constraint :bond_lots, name: "check_bond_lots_non_inflation_rate_fields_present"
    end

    add_check_constraint :bond_lots,
                         "(subtype IN ('inflation_linked')) OR (rate_type IS NOT NULL AND coupon_frequency IS NOT NULL)",
                         name: "check_bond_lots_non_inflation_rate_fields_present"
  end

  def down
    if check_constraint_exists?(:bond_lots, name: "check_bond_lots_non_inflation_rate_fields_present")
      remove_check_constraint :bond_lots, name: "check_bond_lots_non_inflation_rate_fields_present"
    end

    add_check_constraint :bond_lots,
                         "(subtype IN ('inflation_linked', 'savings')) OR (rate_type IS NOT NULL AND coupon_frequency IS NOT NULL)",
                         name: "check_bond_lots_non_inflation_rate_fields_present"
  end
end
