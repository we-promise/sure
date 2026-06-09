# frozen_string_literal: true

class AddNullConstraintsToBitstampTables < ActiveRecord::Migration[7.2]
  def change
    execute "UPDATE bitstamp_items SET name = 'Bitstamp' WHERE name IS NULL"
    execute "UPDATE bitstamp_accounts SET name = 'Unknown' WHERE name IS NULL"
    execute "UPDATE bitstamp_accounts SET account_type = 'unknown' WHERE account_type IS NULL"
    execute "UPDATE bitstamp_accounts SET currency = 'USD' WHERE currency IS NULL"

    change_column_null :bitstamp_items, :name, false
    change_column_null :bitstamp_accounts, :name, false
    change_column_null :bitstamp_accounts, :account_type, false
    change_column_null :bitstamp_accounts, :currency, false
  end
end
