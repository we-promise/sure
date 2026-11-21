class AddParityFlagsToBalancesAndHoldings < ActiveRecord::Migration[8.1]
  def change
    add_column :balances, :holdings_valued_at_parity, :boolean, default: false, null: false
    add_column :holdings, :price_at_parity, :boolean, default: false, null: false
  end
end
