class AddGinIndexToEnableBankingAccountsIdentificationHashes < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_index :enable_banking_accounts, :identification_hashes, using: :gin, algorithm: :concurrently
  end
end
