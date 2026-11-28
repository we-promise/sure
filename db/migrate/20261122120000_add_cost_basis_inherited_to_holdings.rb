class AddCostBasisInheritedToHoldings < ActiveRecord::Migration[8.1]
  def change
    add_column :holdings, :cost_basis_inherited, :boolean, default: false, null: false
  end
end
