class IncreaseSecurityPricePrecision < ActiveRecord::Migration[8.1]
  def up
    change_column :security_prices, :price, :decimal, precision: 19, scale: 10, null: false
    # A holding's price is in the account currency, which can be a low-value
    # unit (VND), so keep a wide integer part alongside the extra decimals.
    change_column :holdings, :price, :decimal, precision: 28, scale: 10, null: false
  end

  def down
    change_column :holdings, :price, :decimal, precision: 19, scale: 4, null: false
    change_column :security_prices, :price, :decimal, precision: 19, scale: 4, null: false
  end
end
