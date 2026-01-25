class RenameRawInvestmentsPayloadToRawHoldingsPayload < ActiveRecord::Migration[7.2]
  def change
    rename_column :plaid_accounts, :raw_investments_payload, :raw_holdings_payload
  end
end
