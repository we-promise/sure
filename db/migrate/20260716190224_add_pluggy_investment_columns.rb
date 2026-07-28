class AddPluggyInvestmentColumns < ActiveRecord::Migration[8.1]
  def change
    add_column :pluggy_accounts, :raw_holdings_payload, :jsonb, null: false, default: []
    add_column :pluggy_accounts, :raw_activities_payload, :jsonb, null: false, default: []
    add_column :pluggy_accounts, :cash_balance, :decimal, precision: 19, scale: 4
    add_column :pluggy_accounts, :last_holdings_sync, :datetime
    add_column :pluggy_accounts, :last_activities_sync, :datetime
    add_column :pluggy_accounts, :activities_fetch_pending, :boolean, null: false, default: false
  end
end
