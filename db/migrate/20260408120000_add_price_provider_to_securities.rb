class AddPriceProviderToSecurities < ActiveRecord::Migration[7.2]
  def change
    add_column :securities, :price_provider, :string
    add_index :securities, :price_provider
  end
end
