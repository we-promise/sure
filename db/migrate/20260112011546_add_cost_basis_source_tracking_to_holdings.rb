class AddCostBasisSourceTrackingToHoldings < ActiveRecord::Migration[7.2]
  def change
    add_column :holdings, :cost_basis_source, :string
    add_column :holdings, :cost_basis_locked, :boolean, default: false, null: false
  end
end
