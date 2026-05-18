class RestrictGoalAccountsAccountFk < ActiveRecord::Migration[7.2]
  # Goal#must_have_at_least_one_linked_account is enforced at write time
  # via model validation, but the original goal_accounts → accounts FK
  # was on_delete: :cascade. Deleting a linked account silently destroys
  # the goal_account row, and a Goal whose only link points at that
  # account ends up with zero linked accounts — the model invariant the
  # validation was meant to guarantee. Flip the FK to :restrict so the
  # DB rejects the deletion. Callers (Account#destroy paths) must detach
  # the account from goals first.
  def up
    remove_foreign_key :goal_accounts, :accounts
    add_foreign_key :goal_accounts, :accounts, on_delete: :restrict
  end

  def down
    remove_foreign_key :goal_accounts, :accounts
    add_foreign_key :goal_accounts, :accounts, on_delete: :cascade
  end
end
