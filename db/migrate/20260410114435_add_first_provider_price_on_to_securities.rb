class AddFirstProviderPriceOnToSecurities < ActiveRecord::Migration[7.2]
  def change
    add_column :securities, :first_provider_price_on, :date
  end
end
