class AddMaterializedToHoldings < ActiveRecord::Migration[8.1]
  def change
    add_column :holdings, :materialized, :boolean, default: false, null: false
  end
end
