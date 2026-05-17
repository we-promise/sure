class ChangeBudgetsUserFkOnDeleteToRestrict < ActiveRecord::Migration[7.2]
  def up
    # Replace existing FK with ON DELETE CASCADE to remove personal budgets when
    # their owning user is deleted. This prevents orphaned user references and
    # aligns with the requested behavior.
    remove_foreign_key :budgets, :users
    add_foreign_key :budgets, :users, on_delete: :cascade
  end

  def down
    remove_foreign_key :budgets, :users
    # restore previous behavior; adjust if another prior behavior was used
    add_foreign_key :budgets, :users, on_delete: :nullify
  end
end
