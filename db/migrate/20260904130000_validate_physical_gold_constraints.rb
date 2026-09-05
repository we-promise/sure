class ValidatePhysicalGoldConstraints < ActiveRecord::Migration[7.2]
  CONSTRAINTS = %w[
    investments_gold_weight_positive
    investments_gold_weight_unit_valid
    investments_gold_karat_valid
    investments_gold_manual_value_nonnegative
    investments_gold_details_require_gold_subtype
    investments_gold_form_valid
    investments_gold_form_requires_gold_subtype
    investments_physical_gold_details_require_physical_form
  ].freeze

  def up
    CONSTRAINTS.each do |constraint|
      validate_check_constraint :investments, name: constraint
    end
  end

  def down
  end
end
