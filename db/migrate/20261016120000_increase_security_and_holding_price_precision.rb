class IncreaseSecurityAndHoldingPricePrecision < ActiveRecord::Migration[8.1]
  # Prices of low-value assets (e.g. BONK at 0.000002891) were rounded to 0 at scale 4.
  # Match trades.price (see IncreaseTradePricePrecision).
  def up
    change_column :security_prices, :price, :decimal, precision: 19, scale: 10, null: false
    change_column :holdings, :price, :decimal, precision: 19, scale: 10, null: false
  end

  def down
    change_column :security_prices, :price, :decimal, precision: 19, scale: 4, null: false
    change_column :holdings, :price, :decimal, precision: 19, scale: 4, null: false
  end
end
