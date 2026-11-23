class AddHoldingsRequestedAtToSimplefinAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :simplefin_accounts, :holdings_requested_at, :datetime
    add_column :simplefin_accounts, :account_requested_at, :datetime
  end
end
