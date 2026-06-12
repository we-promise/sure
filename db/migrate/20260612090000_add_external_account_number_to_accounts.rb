class AddExternalAccountNumberToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :accounts, :external_account_number, :string
    # Non-unique on purpose: it is a matching hint for spreadsheet/statement
    # imports (e.g. the RIB/account number from an .xlsx), and the same number
    # can legitimately back more than one sheet (a current account plus its
    # monthly card-expense sheets).
    add_index :accounts, [ :family_id, :external_account_number ],
              name: "index_accounts_on_family_and_external_number"
  end
end
