class CascadeBudgetDeleteToSavingsContributions < ActiveRecord::Migration[7.2]
  def up
    remove_foreign_key :savings_contributions, :budgets
    add_foreign_key :savings_contributions, :budgets, on_delete: :cascade
  end

  def down
    remove_foreign_key :savings_contributions, :budgets
    add_foreign_key :savings_contributions, :budgets
  end
end
