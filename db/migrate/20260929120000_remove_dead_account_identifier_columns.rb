# frozen_string_literal: true

class RemoveDeadAccountIdentifierColumns < ActiveRecord::Migration[8.1]
  def up
    remove_column :questrade_accounts, :account_number
    remove_column :redbark_accounts, :account_number
    remove_column :monobank_accounts, :iban
    remove_column :monobank_accounts, :masked_pan
  end

  def down
    add_column :questrade_accounts, :account_number, :string
    add_column :redbark_accounts, :account_number, :string
    add_column :monobank_accounts, :iban, :string
    add_column :monobank_accounts, :masked_pan, :string
  end
end
