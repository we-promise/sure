class AddMonthRangeConstraintsToInflationTables < ActiveRecord::Migration[7.2]
  def change
    add_check_constraint :gus_inflation_rates,
                         "month BETWEEN 1 AND 12",
                         name: "chk_gus_inflation_rates_month_range"

    add_check_constraint :inflation_rates,
                         "month BETWEEN 1 AND 12",
                         name: "chk_inflation_rates_month_range"
  end
end
