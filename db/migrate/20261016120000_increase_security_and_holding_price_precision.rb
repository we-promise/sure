class IncreaseSecurityAndHoldingPricePrecision < ActiveRecord::Migration[8.1]
  # Prices of low-value assets (e.g. BONK at 0.000002891) were rounded to 0 at scale 4.
  # Scale 10 like trades.price (see IncreaseTradePricePrecision); precision 25
  # keeps the 15 whole-number digits that decimal(19, 4) allowed.
  def up
    change_column :security_prices, :price, :decimal, precision: 25, scale: 10, null: false
    change_column :holdings, :price, :decimal, precision: 25, scale: 10, null: false
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Reducing security and holding prices to four decimal places would round low-value asset prices to 0"
  end
end
