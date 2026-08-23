class AddRolloverToBudgetCategories < ActiveRecord::Migration[7.2]
  def change
    add_column :budget_categories, :rollover_enabled, :boolean, null: false, default: false
    add_column :budget_categories, :rolled_over_amount, :decimal, precision: 19, scale: 4, null: false, default: 0
  end
end
