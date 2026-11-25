class AddSupersededToHoldings < ActiveRecord::Migration[8.1]
  def change
    add_column :holdings, :superseded, :boolean, default: false, null: false
  end
end
