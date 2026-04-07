class AddBondLotEnumCheckConstraints < ActiveRecord::Migration[7.2]
  def up
    add_check_constraint :bond_lots,
                         "subtype IN ('zero_coupon','fixed_coupon','inflation_linked','savings','other')",
                         name: "check_bond_lots_subtype_valid"
    add_check_constraint :bond_lots,
                         "rate_type IS NULL OR rate_type IN ('fixed','variable')",
                         name: "check_bond_lots_rate_type_valid"
    add_check_constraint :bond_lots,
                         "coupon_frequency IS NULL OR coupon_frequency IN ('monthly','quarterly','semi_annual','annual','at_maturity')",
                         name: "check_bond_lots_coupon_frequency_valid"
    add_check_constraint :bond_lots,
                         "tax_strategy IN ('standard','reduced','exempt')",
                         name: "check_bond_lots_tax_strategy_valid"
  end

  def down
    remove_check_constraint :bond_lots, name: "check_bond_lots_subtype_valid"
    remove_check_constraint :bond_lots, name: "check_bond_lots_rate_type_valid"
    remove_check_constraint :bond_lots, name: "check_bond_lots_coupon_frequency_valid"
    remove_check_constraint :bond_lots, name: "check_bond_lots_tax_strategy_valid"
  end
end
