class AddRawEquitySummaryPayloadToIbkrAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :ibkr_accounts, :raw_equity_summary_payload, :jsonb, default: [], null: false
  end
end
