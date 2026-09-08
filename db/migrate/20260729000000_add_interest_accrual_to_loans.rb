class AddInterestAccrualToLoans < ActiveRecord::Migration[7.2]
  def change
    add_column :loans, :accrue_interest, :boolean, default: false, null: false
    add_column :loans, :interest_accrual_day, :integer
    add_column :loans, :interest_accrual_start_date, :date

    add_check_constraint :loans,
      "interest_accrual_day IS NULL OR (interest_accrual_day >= 1 AND interest_accrual_day <= 31)",
      name: "loans_interest_accrual_day_check"
  end
end
