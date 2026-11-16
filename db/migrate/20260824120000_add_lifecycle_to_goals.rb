class AddLifecycleToGoals < ActiveRecord::Migration[7.2]
  def change
    # Frozen at the moment `complete` fires, so a reached goal keeps showing
    # what it actually reached even after the money is spent. Nullable, and
    # deliberately NOT backfilled: an already-completed goal's past value
    # cannot be recovered, and guessing it would freeze an already-eroded
    # number — the wrong one. `Goal#current_balance` falls back to the live
    # calculation whenever this is nil.
    add_column :goals, :completed_amount, :decimal, precision: 19, scale: 4
    add_column :goals, :completed_at, :datetime

    # Introduced here without behavior on purpose. Lots B3 (maintained
    # reserves) and B4 (partial consumption) both branch on it, and adding
    # the column with them would mean retrofitting the lifecycle written
    # here. Everything is `one_off` until B3 gives `maintained` a meaning.
    add_column :goals, :kind, :string, null: false, default: "one_off"
    add_check_constraint :goals, "kind IN ('one_off','maintained')", name: "chk_goals_kind_enum"
  end
end
