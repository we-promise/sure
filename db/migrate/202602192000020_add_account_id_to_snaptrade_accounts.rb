# frozen_string_literal: true

# Links a SnapTrade account row to the provider's account identifier (string),
# scoped per snaptrade_item. Required before 20260219200003_scope_snaptrade_account_uniqueness_to_item.
class AddAccountIdToSnaptradeAccounts < ActiveRecord::Migration[7.2]
  def up
    return if column_exists?(:snaptrade_accounts, :account_id)

    add_column :snaptrade_accounts, :account_id, :string
  end

  def down
    return unless column_exists?(:snaptrade_accounts, :account_id)

    remove_column :snaptrade_accounts, :account_id
  end
end
