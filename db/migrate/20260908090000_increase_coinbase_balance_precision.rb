# frozen_string_literal: true

class IncreaseCoinbaseBalancePrecision < ActiveRecord::Migration[8.1]
  def up
    change_column :coinbase_accounts, :current_balance, :decimal, precision: 24, scale: 8
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Reducing Coinbase balances to four decimal places would discard imported cryptocurrency precision"
  end
end
