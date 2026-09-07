class AddDayCountConventionToLoans < ActiveRecord::Migration[8.1]
  def change
    add_column :loans, :day_count_convention, :string, null: false, default: "actual_365"

    add_check_constraint :loans,
      "day_count_convention IN ('actual_365', 'actual_actual')",
      name: "chk_loans_day_count_convention"
  end
end
