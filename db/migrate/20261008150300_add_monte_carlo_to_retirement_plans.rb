class AddMonteCarloToRetirementPlans < ActiveRecord::Migration[8.1]
  def change
    change_table :retirement_plans, bulk: true do |t|
      # The standard deviation of the yearly log return: how far a year's
      # return strays from the expected one.
      t.decimal :return_volatility, precision: 5, scale: 4, null: false, default: "0.12"
      # The share of simulated paths that must last to the end age for a year
      # to count as a confident retirement year.
      t.decimal :success_target, precision: 5, scale: 4, null: false, default: "0.9"
    end

    add_check_constraint :retirement_plans, "return_volatility >= 0 AND return_volatility <= 1",
      name: "chk_retirement_plans_return_volatility"
    add_check_constraint :retirement_plans, "success_target > 0 AND success_target <= 1",
      name: "chk_retirement_plans_success_target"
  end
end
