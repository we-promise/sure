class ChangeBudgetsUserFkToCascade < ActiveRecord::Migration[7.2]
  def up
    # Replace existing FK with ON DELETE CASCADE to remove personal budgets when
    # their owning user is deleted. This prevents orphaned user references and
    # aligns with the requested behavior.
    #
    # CAUTION: This is a DESTRUCTIVE operation. When a user is deleted,
    # all personal budgets (user_id ≠ NULL) for that user will be automatically
    # deleted from the database. This ensures no orphaned rows but results in
    # data loss if those budgets were important.
    #
    # This migration replaces the incorrectly-named predecessor migration
    # (20260517120000_change_budgets_user_fk_on_delete_to_restrict.rb) which had
    # the same intent but a misleading name (suggested RESTRICT when actually
    # implementing CASCADE).
    remove_foreign_key :budgets, :users
    add_foreign_key :budgets, :users, on_delete: :cascade
  end

  def down
    remove_foreign_key :budgets, :users
    add_foreign_key :budgets, :users, on_delete: :nullify
  end
end

