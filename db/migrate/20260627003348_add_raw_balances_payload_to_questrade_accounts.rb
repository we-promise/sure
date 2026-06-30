# frozen_string_literal: true

class AddRawBalancesPayloadToQuestradeAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :questrade_accounts, :raw_balances_payload, :jsonb
  end
end
