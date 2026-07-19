class AddAllocationToGoalAccounts < ActiveRecord::Migration[7.2]
  def change
    # Per-account earmark toward a goal. NULL = "dedicate the whole account
    # balance" (the v1 behaviour), so every existing goal_accounts row keeps
    # its current semantics with no backfill. A set amount reserves a fixed
    # slice of the account, letting one account fund several goals without
    # double-counting (Goal#current_balance applies the shared-pool math).
    add_column :goal_accounts, :allocated_amount, :decimal, precision: 19, scale: 4, null: true

    add_check_constraint :goal_accounts,
                         "allocated_amount IS NULL OR allocated_amount >= 0",
                         name: "chk_goal_accounts_allocation_non_negative"
  end
end
