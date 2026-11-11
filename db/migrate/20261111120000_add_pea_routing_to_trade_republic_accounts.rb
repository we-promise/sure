class AddPeaRoutingToTradeRepublicAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :trade_republic_accounts, :provider_cash_account_id, :string
    add_column :trade_republic_accounts, :timeline_backfilled_at, :datetime
  end
end
