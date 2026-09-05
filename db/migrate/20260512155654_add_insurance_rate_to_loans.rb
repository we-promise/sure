class AddInsuranceRateToLoans < ActiveRecord::Migration[7.2]
  def change
    add_column :loans, :insurance_rate, :decimal, precision: 8, scale: 4
    add_check_constraint :loans,
      "insurance_rate IS NULL OR insurance_rate >= 0",
      name: "chk_loans_insurance_rate_non_negative"
  end
end
