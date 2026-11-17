class AddOwnershipPercentageToAccountsAndAccountShares < ActiveRecord::Migration[8.1]
  def change
    # Share of the account each person counts towards their own net worth.
    # accounts.ownership_percentage is the owner's share; account_shares holds
    # each co-owner's share. Defaults to 100 so existing behaviour is unchanged.
    # The guards let it run on databases that already applied this change under
    # its earlier version number (20260923120000).
    add_column :accounts, :ownership_percentage, :decimal, precision: 5, scale: 2, default: 100, null: false, if_not_exists: true
    add_column :account_shares, :ownership_percentage, :decimal, precision: 5, scale: 2, default: 100, null: false, if_not_exists: true

    add_check_constraint :accounts, "ownership_percentage >= 0 AND ownership_percentage <= 100", name: "chk_accounts_ownership_percentage", if_not_exists: true
    add_check_constraint :account_shares, "ownership_percentage >= 0 AND ownership_percentage <= 100", name: "chk_account_shares_ownership_percentage", if_not_exists: true
  end
end
