class AddInsuranceRateTypeToLoans < ActiveRecord::Migration[7.2]
  def change
    add_column :loans, :insurance_rate_type, :string
  end
end
