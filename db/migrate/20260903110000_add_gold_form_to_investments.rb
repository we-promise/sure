class AddGoldFormToInvestments < ActiveRecord::Migration[8.0]
  def up
    add_column :investments, :gold_form, :string
    execute "UPDATE investments SET gold_form = 'physical' WHERE subtype = 'gold'"

    add_check_constraint :investments,
                         "gold_form IS NULL OR gold_form IN ('physical', 'digital')",
                         name: "investments_gold_form_valid"
    add_check_constraint :investments,
                         "gold_form IS NULL OR subtype = 'gold'",
                         name: "investments_gold_form_requires_gold_subtype"
    add_check_constraint :investments,
                         "gold_form = 'physical' OR (gold_weight IS NULL AND gold_weight_unit IS NULL AND gold_karat IS NULL AND gold_manual_value IS NULL)",
                         name: "investments_physical_gold_details_require_physical_form"
  end

  def down
    remove_check_constraint :investments, name: "investments_physical_gold_details_require_physical_form"
    remove_check_constraint :investments, name: "investments_gold_form_requires_gold_subtype"
    remove_check_constraint :investments, name: "investments_gold_form_valid"
    remove_column :investments, :gold_form
  end
end
