class IncreaseSecurityPricePrecision < ActiveRecord::Migration[8.1]
  def up
    change_column :security_prices, :price, :decimal, precision: 19, scale: 10, null: false
  end

  def down
    change_column :security_prices, :price, :decimal, precision: 19, scale: 4, null: false
  end
end
