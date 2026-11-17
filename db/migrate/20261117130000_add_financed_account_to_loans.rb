class AddFinancedAccountToLoans < ActiveRecord::Migration[8.1]
  def change
    # The asset (a property or vehicle) a loan was taken out to buy. Deleting
    # that account clears the link rather than the loan.
    add_reference :loans, :financed_account, type: :uuid, null: true, index: true,
                  foreign_key: { to_table: :accounts, on_delete: :nullify }
  end
end
