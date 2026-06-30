# frozen_string_literal: true

class AddRawBalancesPayloadToQuestradeAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :questrade_accounts, :raw_balances_payload, :jsonb
  end
end
