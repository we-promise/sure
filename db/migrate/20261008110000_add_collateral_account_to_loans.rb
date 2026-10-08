class AddCollateralAccountToLoans < ActiveRecord::Migration[8.1]
  def change
    # The property or vehicle that secures the loan. Nullable: most loans are not
    # linked, and deleting the asset must unlink the loan rather than fail or
    # orphan it.
    add_reference :loans, :collateral_account, type: :uuid, null: true, index: true,
      foreign_key: { to_table: :accounts, on_delete: :nullify }
  end
end
