class AddCashEquivalentToHoldings < ActiveRecord::Migration[7.2]
  def change
    add_column :holdings, :cash_equivalent, :boolean, default: false, null: false
  end
end
