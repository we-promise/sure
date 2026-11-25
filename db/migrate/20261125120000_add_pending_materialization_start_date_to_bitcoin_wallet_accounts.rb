class AddPendingMaterializationStartDateToBitcoinWalletAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :bitcoin_wallet_accounts, :pending_materialization_start_date, :date
  end
end
