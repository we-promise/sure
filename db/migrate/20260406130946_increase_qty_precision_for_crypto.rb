class IncreaseQtyPrecisionForCrypto < ActiveRecord::Migration[7.2]
  def change
    change_column :trades, :qty, :decimal, precision: 19, scale: 10
    change_column :holdings, :qty, :decimal, precision: 19, scale: 10
  end
end
