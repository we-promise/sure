class AddCollateralAccountToLoans < ActiveRecord::Migration[8.1]
  def up
    # A database can already have this column from an earlier migration that
    # recorded a different version, so this one is still pending there. Leave
    # the column, its index, its foreign key and every loan's link as they are.
    return if column_exists?(:loans, :collateral_account_id)

    # The property or vehicle that secures the loan. Nullable: most loans are not
    # linked, and deleting the asset must unlink the loan rather than fail or
    # orphan it.
    add_reference :loans, :collateral_account, type: :uuid, null: true, index: true,
      foreign_key: { to_table: :accounts, on_delete: :nullify }
  end

  def down
    remove_reference :loans, :collateral_account, index: true, foreign_key: { to_table: :accounts }
  end
end
