class AddInstitutionFieldsToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :accounts, :institution_name, :string
    add_column :accounts, :institution_domain, :string
    add_column :accounts, :notes, :text

    # Touch all accounts to invalidate cached queries that depend on accounts.maximum(:updated_at)
    # Without this, the following error would occur post-update and prevent page loads:
    # "undefined method 'institution_domain' for an instance of BalanceSheet::AccountTotals::AccountRow"
    Account.in_batches.update_all(updated_at: Time.current)
  end
end
