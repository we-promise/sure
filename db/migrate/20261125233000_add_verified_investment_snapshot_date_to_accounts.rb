class AddVerifiedInvestmentSnapshotDateToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :verified_investment_snapshot_date, :date
  end
end
