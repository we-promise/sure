class MakePhysicalGoldConstraintsNullSafe < ActiveRecord::Migration[7.2]
  def change
    remove_check_constraint :investments, name: "investments_gold_details_require_gold_subtype"
    remove_check_constraint :investments, name: "investments_gold_form_requires_gold_subtype"
    remove_check_constraint :investments, name: "investments_physical_gold_details_require_physical_form"

    add_check_constraint :investments,
                         "subtype IS NOT DISTINCT FROM 'gold' OR (gold_weight IS NULL AND gold_weight_unit IS NULL AND gold_karat IS NULL AND gold_manual_value IS NULL)",
                         name: "investments_gold_details_require_gold_subtype",
                         validate: false
    add_check_constraint :investments,
                         "gold_form IS NULL OR subtype IS NOT DISTINCT FROM 'gold'",
                         name: "investments_gold_form_requires_gold_subtype",
                         validate: false
    add_check_constraint :investments,
                         "gold_form IS NOT DISTINCT FROM 'physical' OR (gold_weight IS NULL AND gold_weight_unit IS NULL AND gold_karat IS NULL AND gold_manual_value IS NULL)",
                         name: "investments_physical_gold_details_require_physical_form",
                         validate: false
  end
end
