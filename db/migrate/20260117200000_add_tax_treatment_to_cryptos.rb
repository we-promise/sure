class AddTaxTreatmentToCryptos < ActiveRecord::Migration[7.2]
  def change
    add_column :cryptos, :tax_treatment, :string, default: "taxable", null: false
  end
end
