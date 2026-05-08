class SimplifyIbkrAccountPayloads < ActiveRecord::Migration[7.2]
  def change
    remove_column :ibkr_accounts, :account_alias, :string
    remove_column :ibkr_accounts, :account_type, :string
    remove_column :ibkr_accounts, :raw_payload, :jsonb
    remove_column :ibkr_accounts, :raw_instruments_payload, :jsonb
  end
end
