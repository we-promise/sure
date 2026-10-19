class AddEnableBankingFingerprintToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :enable_banking_fingerprint, :string
    add_index :accounts, [ :family_id, :enable_banking_fingerprint ], unique: true,
              where: "enable_banking_fingerprint IS NOT NULL", name: "index_accounts_on_enable_banking_identity"
  end
end
