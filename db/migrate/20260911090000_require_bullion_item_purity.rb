class RequireBullionItemPurity < ActiveRecord::Migration[8.1]
  def up
    add_check_constraint :valuable_items,
      "item_type = 'gemstone' OR purity IS NOT NULL",
      name: "valuable_items_bullion_purity_present",
      validate: false
  end

  def down
    remove_check_constraint :valuable_items, name: "valuable_items_bullion_purity_present"
  end
end
