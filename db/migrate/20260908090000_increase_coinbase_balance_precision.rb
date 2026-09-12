# frozen_string_literal: true

class IncreaseCoinbaseBalancePrecision < ActiveRecord::Migration[8.1]
  def up
    change_column :coinbase_accounts, :current_balance, :decimal, precision: 34, scale: 18
    change_column :holdings, :qty, :decimal, precision: 34, scale: 18, null: false
    change_column :trades, :qty, :decimal, precision: 34, scale: 18
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Reducing Coinbase balances to four decimal places would discard imported cryptocurrency precision"
  end
end
