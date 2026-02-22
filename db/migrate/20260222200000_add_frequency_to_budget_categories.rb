class AddFrequencyToBudgetCategories < ActiveRecord::Migration[7.2]
  def change
    add_column :budget_categories, :budget_frequency, :string, default: "monthly", null: false
    add_column :budget_categories, :annual_amount, :decimal, precision: 19, scale: 4
  end
end
