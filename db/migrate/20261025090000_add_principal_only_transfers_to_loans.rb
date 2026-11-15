class AddPrincipalOnlyTransfersToLoans < ActiveRecord::Migration[8.1]
  # A linked transfer can be the principal part of a payment whose interest is
  # recorded separately. No ledger marker reliably says so, so the borrower
  # sets the behaviour per loan instead of the replay guessing from an amount.
  def change
    add_column :loans, :principal_only_transfers, :boolean, default: false, null: false
  end
end
