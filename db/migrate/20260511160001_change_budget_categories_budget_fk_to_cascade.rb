class ChangeBudgetCategoriesBudgetFkToCascade < ActiveRecord::Migration[7.2]
  # budgets.user_id now cascades at the DB level when a user is deleted
  # (see 20260511160000). That DB-level cascade bypasses Budget's
  # `dependent: :destroy` on budget_categories, so without this, deleting a
  # user with an initialized personal budget would fail on the
  # budget_categories -> budgets foreign key.
  def up
    remove_foreign_key :budget_categories, :budgets
    add_foreign_key :budget_categories, :budgets, on_delete: :cascade
  end

  def down
    remove_foreign_key :budget_categories, :budgets
    add_foreign_key :budget_categories, :budgets
  end
end
