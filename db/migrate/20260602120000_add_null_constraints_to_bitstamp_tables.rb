# frozen_string_literal: true

class AddNullConstraintsToBitstampTables < ActiveRecord::Migration[7.2]
  def up
    execute "UPDATE bitstamp_items SET name = 'Bitstamp' WHERE name IS NULL"
    execute "UPDATE bitstamp_accounts SET name = 'Unknown' WHERE name IS NULL"
    execute "UPDATE bitstamp_accounts SET account_type = 'unknown' WHERE account_type IS NULL"

    null_currency_count = select_value("SELECT COUNT(*) FROM bitstamp_accounts WHERE currency IS NULL").to_i
    if null_currency_count > 0
      raise "Cannot add NOT NULL constraint to bitstamp_accounts.currency: " \
            "#{null_currency_count} row(s) have a NULL currency. " \
            "Repair these rows from the persisted provider payload before re-running this migration."
    end

    change_column_null :bitstamp_items, :name, false
    change_column_null :bitstamp_accounts, :name, false
    change_column_null :bitstamp_accounts, :account_type, false
    change_column_null :bitstamp_accounts, :currency, false
  end

  def down
    change_column_null :bitstamp_items, :name, true
    change_column_null :bitstamp_accounts, :name, true
    change_column_null :bitstamp_accounts, :account_type, true
    change_column_null :bitstamp_accounts, :currency, true
  end
end
