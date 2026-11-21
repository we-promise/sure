class AddInvestmentSubtypeRegionsToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :investment_subtype_regions, :string, array: true
  end
end
