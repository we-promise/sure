class IncreaseCryptoQuantityPrecision < ActiveRecord::Migration[7.2]
  def up
    change_column :holdings, :qty, :decimal, precision: 24, scale: 8, null: false
    change_column :trades, :qty, :decimal, precision: 24, scale: 8
  end

  def down
    change_column :holdings, :qty, :decimal, precision: 19, scale: 4, null: false
    change_column :trades, :qty, :decimal, precision: 19, scale: 4
  end
end
