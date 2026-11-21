class AddCarriedForwardToSecurityPrices < ActiveRecord::Migration[8.1]
  def change
    add_column :security_prices, :carried_forward, :boolean, default: false, null: false
  end
end
