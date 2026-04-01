class EnforceBondLotConstraintsAndDefaults < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      UPDATE bond_lots
      SET subtype = 'other_bond'
      WHERE subtype IS NULL
    SQL

    change_column_default :bond_lots, :subtype, from: "other", to: "other_bond"
    change_column_null :bond_lots, :subtype, false

    add_check_constraint :bond_lots, "amount > 0", name: "check_bond_lots_positive_amount", if_not_exists: true
    add_check_constraint :bond_lots, "term_months > 0", name: "check_bond_lots_positive_term", if_not_exists: true
    add_check_constraint :bond_lots, "maturity_date >= purchased_on", name: "check_bond_lots_maturity_after_purchase", if_not_exists: true
    add_check_constraint :bond_lots, "subtype IS NOT NULL", name: "check_bond_lots_subtype_not_null", if_not_exists: true
    add_check_constraint :bond_lots,
                         "subtype IN ('eod', 'rod') OR (rate_type IS NOT NULL AND coupon_frequency IS NOT NULL)",
                         name: "check_bond_lots_non_inflation_rate_fields_present",
                         if_not_exists: true
  end

  def down
    remove_check_constraint :bond_lots, name: "check_bond_lots_non_inflation_rate_fields_present", if_exists: true
    remove_check_constraint :bond_lots, name: "check_bond_lots_subtype_not_null", if_exists: true
    remove_check_constraint :bond_lots, name: "check_bond_lots_maturity_after_purchase", if_exists: true
    remove_check_constraint :bond_lots, name: "check_bond_lots_positive_term", if_exists: true
    remove_check_constraint :bond_lots, name: "check_bond_lots_positive_amount", if_exists: true

    change_column_null :bond_lots, :subtype, false
    change_column_default :bond_lots, :subtype, from: "other_bond", to: "other"
  end
end
