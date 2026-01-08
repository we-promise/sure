class AddProvisionalToSecurityPrices < ActiveRecord::Migration[7.2]
  def change
    add_column :security_prices, :provisional, :boolean, default: false, null: false
  end
end
