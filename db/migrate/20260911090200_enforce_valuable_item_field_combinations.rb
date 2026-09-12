class EnforceValuableItemFieldCombinations < ActiveRecord::Migration[8.1]
  def up
    add_check_constraint :valuable_items,
      "(item_type = 'bullion' AND weight_unit IN ('gram', 'troy_ounce', 'kilogram')) OR (item_type = 'gemstone' AND weight_unit = 'carat')",
      name: "valuable_items_weight_unit_matches_item_type",
      validate: false

    add_check_constraint :valuable_items,
      "(item_type = 'bullion' AND material IN ('gold', 'silver', 'platinum', 'palladium')) OR (item_type = 'gemstone' AND material IN ('diamond', 'ruby', 'sapphire', 'emerald', 'other'))",
      name: "valuable_items_material_matches_item_type",
      validate: false

    add_check_constraint :valuable_items,
      "item_type = 'bullion' OR purity IS NULL",
      name: "valuable_items_gemstone_purity_absent",
      validate: false
  end

  def down
    remove_constraint_if_present("valuable_items_gemstone_purity_absent")
    remove_constraint_if_present("valuable_items_material_matches_item_type")
    remove_constraint_if_present("valuable_items_weight_unit_matches_item_type")
  end

  private
    def remove_constraint_if_present(name)
      return unless check_constraint_exists?(:valuable_items, name:)

      remove_check_constraint :valuable_items, name:
    end
end
