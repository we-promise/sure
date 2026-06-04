class AddRawBalancesPayloadToSnaptradeAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :snaptrade_accounts, :raw_balances_payload, :jsonb, default: []
  end
end
