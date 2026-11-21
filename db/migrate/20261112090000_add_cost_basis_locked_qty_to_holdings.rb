class AddCostBasisLockedQtyToHoldings < ActiveRecord::Migration[8.1]
  # The units a manual cost basis was set for, and the per-unit figure the
  # user gave for them. The row's own qty is rewritten by every sync, and its
  # cost_basis shows the blend once a later-entered trade adds units, so
  # neither can tell what the user stated. Existing locks stay nil: they cover
  # every unit held, at the row's cost_basis.
  def change
    add_column :holdings, :cost_basis_locked_qty, :decimal, precision: 34, scale: 18
    add_column :holdings, :cost_basis_locked_unit_cost, :decimal, precision: 19, scale: 4
  end
end
