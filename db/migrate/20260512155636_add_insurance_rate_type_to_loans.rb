class AddInsuranceRateTypeToLoans < ActiveRecord::Migration[7.2]
  def change
    add_column :loans, :insurance_rate_type, :string
    add_check_constraint :loans,
      "insurance_rate_type IS NULL OR insurance_rate_type IN ('level_term', 'decreasing_life')",
      name: "chk_loans_insurance_rate_type"
  end
end
