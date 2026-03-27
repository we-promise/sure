class IncreaseCryptoQuantityPrecision < ActiveRecord::Migration[7.2]
  def change
    change_column :holdings, :qty, :decimal, precision: 24, scale: 8, null: false
    change_column :trades, :qty, :decimal, precision: 24, scale: 8
  end
end
