class AddCostBasisCarriedToHoldings < ActiveRecord::Migration[8.1]
  # Existing rows are left unmarked. A lock the provider import copied forward
  # cannot be told from one the user set at the same figure, and after a buy
  # the latter is a new opening basis. Read as the user's own, a copy keeps the
  # figure it already shows and is released by unlocking the position's latest
  # lock; marked wrongly, a user's lock would be ignored and cleared.
  def change
    add_column :holdings, :cost_basis_carried, :boolean, default: false, null: false
  end
end
