class AddPhysicalGoldConstraintsToInvestments < ActiveRecord::Migration[7.2]
  def change
    add_check_constraint :investments,
                         "gold_weight IS NULL OR gold_weight > 0",
                         name: "investments_gold_weight_positive",
                         validate: false
    add_check_constraint :investments,
                         "gold_weight_unit IS NULL OR gold_weight_unit IN ('gram', 'troy_ounce', 'kilogram')",
                         name: "investments_gold_weight_unit_valid",
                         validate: false
    add_check_constraint :investments,
                         "gold_karat IS NULL OR (gold_karat > 0 AND gold_karat <= 24)",
                         name: "investments_gold_karat_valid",
                         validate: false
    add_check_constraint :investments,
                         "gold_manual_value IS NULL OR gold_manual_value >= 0",
                         name: "investments_gold_manual_value_nonnegative",
                         validate: false
    add_check_constraint :investments,
                         "subtype IS NOT DISTINCT FROM 'gold' OR (gold_weight IS NULL AND gold_weight_unit IS NULL AND gold_karat IS NULL AND gold_manual_value IS NULL)",
                         name: "investments_gold_details_require_gold_subtype",
                         validate: false
  end
end
