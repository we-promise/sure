class AddGinIndexToEnableBankingAccountsIdentificationHashes < ActiveRecord::Migration[7.2]
  def change
    add_index :enable_banking_accounts, :identification_hashes, using: :gin
  end
end