class AddInsuranceRateToLoans < ActiveRecord::Migration[7.2]
  def change
    add_column :loans, :insurance_rate, :decimal, precision: 8, scale: 4
  end
end
