class AddQuantityToValuableItems < ActiveRecord::Migration[8.1]
  def up
    add_column :valuable_items, :quantity, :integer, null: false, default: 1
    add_check_constraint :valuable_items, "quantity > 0", name: "valuable_items_quantity_positive"
  end

  def down
    remove_check_constraint :valuable_items, name: "valuable_items_quantity_positive"
    remove_column :valuable_items, :quantity
  end
end
