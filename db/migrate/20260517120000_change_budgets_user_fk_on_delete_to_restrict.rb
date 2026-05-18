class ChangeBudgetsUserFkOnDeleteToRestrict < ActiveRecord::Migration[7.2]
  # NOTE: This migration had a misleading name (suggested RESTRICT when actually
  # implementing CASCADE). It has been superseded by the correctly-named migration
  # 20260517120001_change_budgets_user_fk_to_cascade.rb.
  #
  # This migration remains as a NO-OP to preserve migration history and allow
  # existing dev/test databases that have already executed it to continue without error.
  # On production or fresh environments, only 20260517120001 will be executed.

  def up
    # NO-OP: The actual FK change is implemented in the replacement migration
    # 20260517120001_change_budgets_user_fk_to_cascade.rb
  end

  def down
    # NO-OP
  end
end
