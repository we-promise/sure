class AddAutoContributionBudgetCheckConstraint < ActiveRecord::Migration[7.2]
  # Defense-in-depth at the DB level: an auto-source contribution must
  # always carry a non-null budget_id. Without this, the partial unique
  # index `WHERE source = 'auto'` on (savings_goal_id, budget_id) would
  # not catch duplicate rows where budget_id is NULL (Postgres treats
  # NULLs as distinct). The application-level
  # `budget_required_for_auto_source` model validation already rejects
  # this; the constraint stops anything that bypasses validations
  # (raw SQL, console save without validation, future bulk insert) from
  # corrupting the invariant.
  def change
    add_check_constraint :savings_contributions,
      "(source <> 'auto') OR (budget_id IS NOT NULL)",
      name: "chk_savings_contributions_auto_requires_budget"
  end
end
