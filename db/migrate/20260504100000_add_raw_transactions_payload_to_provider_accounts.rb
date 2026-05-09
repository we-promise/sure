class AddRawTransactionsPayloadToProviderAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :provider_accounts, :raw_transactions_payload, :jsonb
  end
end
