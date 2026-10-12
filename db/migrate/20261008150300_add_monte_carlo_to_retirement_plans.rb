class AddMonteCarloToRetirementPlans < ActiveRecord::Migration[8.1]
  def up
    # A database can already have these columns from an earlier migration that
    # recorded a different version, so this one is still pending there. Every
    # step below skips what exists, leaving each plan's settings as they are.

    # The standard deviation of the yearly log return: how far a year's
    # return strays from the expected one.
    add_column :retirement_plans, :return_volatility, :decimal, precision: 5, scale: 4, null: false, default: "0.12",
      if_not_exists: true
    # The share of simulated paths that must last to the end age for a year
    # to count as a confident retirement year.
    add_column :retirement_plans, :success_target, :decimal, precision: 5, scale: 4, null: false, default: "0.9",
      if_not_exists: true

    add_check_constraint_unless_named :retirement_plans, "return_volatility >= 0 AND return_volatility <= 1",
      name: "chk_retirement_plans_return_volatility"
    add_check_constraint_unless_named :retirement_plans, "success_target > 0 AND success_target <= 1",
      name: "chk_retirement_plans_success_target"
  end

  def down
    remove_check_constraint :retirement_plans, name: "chk_retirement_plans_return_volatility"
    remove_check_constraint :retirement_plans, name: "chk_retirement_plans_success_target"
    remove_columns :retirement_plans, :return_volatility, :success_target
  end

  private
    # Skips on the name alone: a constraint already under that name is the one
    # a re-run must not add again, whatever options it was created with.
    def add_check_constraint_unless_named(table, expression, name:)
      return if check_constraint_exists?(table, name: name)

      add_check_constraint table, expression, name: name
    end
end
