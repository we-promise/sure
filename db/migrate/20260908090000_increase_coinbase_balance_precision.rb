# frozen_string_literal: true

class IncreaseCoinbaseBalancePrecision < ActiveRecord::Migration[7.2]
  def up
    change_column :coinbase_accounts, :current_balance, :decimal, precision: 30, scale: 18
    change_column :holdings, :qty, :decimal, precision: 30, scale: 18, null: false
    change_column :trades, :qty, :decimal, precision: 30, scale: 18
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Reducing Coinbase balances to four decimal places would discard imported cryptocurrency precision"
  end
end
