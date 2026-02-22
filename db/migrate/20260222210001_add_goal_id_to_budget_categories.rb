class AddGoalIdToBudgetCategories < ActiveRecord::Migration[7.2]
  def change
    add_reference :budget_categories, :goal, type: :uuid, null: true, foreign_key: true
  end
end
