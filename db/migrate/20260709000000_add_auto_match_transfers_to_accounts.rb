class AddAutoMatchTransfersToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :accounts, :auto_match_transfers, :boolean, default: true, null: false
  end
end
