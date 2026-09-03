class AddPhysicalGoldConstraintsToInvestments < ActiveRecord::Migration[8.0]
  def change
    add_check_constraint :investments,
                         "gold_weight IS NULL OR gold_weight > 0",
                         name: "investments_gold_weight_positive"
    add_check_constraint :investments,
                         "gold_weight_unit IS NULL OR gold_weight_unit IN ('gram', 'troy_ounce', 'kilogram')",
                         name: "investments_gold_weight_unit_valid"
    add_check_constraint :investments,
                         "gold_karat IS NULL OR (gold_karat > 0 AND gold_karat <= 24)",
                         name: "investments_gold_karat_valid"
    add_check_constraint :investments,
                         "gold_manual_value IS NULL OR gold_manual_value >= 0",
                         name: "investments_gold_manual_value_nonnegative"
    add_check_constraint :investments,
                         "subtype = 'gold' OR (gold_weight IS NULL AND gold_weight_unit IS NULL AND gold_karat IS NULL AND gold_manual_value IS NULL)",
                         name: "investments_gold_details_require_gold_subtype"
  end
end
