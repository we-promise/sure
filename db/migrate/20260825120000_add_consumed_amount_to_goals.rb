class AddConsumedAmountToGoals < ActiveRecord::Migration[7.2]
  def change
    # What has been spent OUT of this goal, on the thing it was for.
    #
    # Progress reads `(backing + consumed) / target`, so spending the money a
    # goal was saved for stops looking like falling behind. Without it, coming
    # home from the holiday the goal paid for dropped it from 100% to 20%, and
    # the only way back was to edit the target — which falsified what the user
    # had actually set out to save.
    #
    # Kept separate from `completed_amount` rather than folded into it: that
    # one freezes the BACKING at closure, and adding consumption to it would
    # count the same money twice on a goal that was partly spent and then
    # closed.
    add_column :goals, :consumed_amount, :decimal, precision: 19, scale: 4, null: false, default: 0

    add_check_constraint :goals, "consumed_amount >= 0",
                         name: "chk_goals_consumed_amount_non_negative"
  end
end
