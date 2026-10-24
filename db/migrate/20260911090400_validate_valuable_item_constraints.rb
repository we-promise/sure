class ValidateValuableItemConstraints < ActiveRecord::Migration[8.1]
  CONSTRAINTS = %w[
    valuable_items_bullion_purity_present
    valuable_items_weight_unit_matches_item_type
    valuable_items_material_matches_item_type
    valuable_items_gemstone_purity_absent
  ].freeze

  def up
    CONSTRAINTS.each do |name|
      validate_check_constraint :valuable_items, name:
    end
  end

  def down
  end
end
