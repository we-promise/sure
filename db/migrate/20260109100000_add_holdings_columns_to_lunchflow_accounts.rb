class AddHoldingsColumnsToLunchflowAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :lunchflow_accounts, :holdings_supported, :boolean, default: true, null: false
    add_column :lunchflow_accounts, :raw_holdings_payload, :jsonb
  end
end
