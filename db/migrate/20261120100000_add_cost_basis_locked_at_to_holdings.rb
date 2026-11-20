class AddCostBasisLockedAtToHoldings < ActiveRecord::Migration[8.1]
  # When the user set a manual cost basis. Its figure covers the units held
  # then; a trade entered afterwards, whatever its date, is not covered, and
  # neither is what is left of its lot after a sale. Existing locks stay nil
  # and fall back to the quantity they were set for.
  def change
    add_column :holdings, :cost_basis_locked_at, :datetime
  end
end
