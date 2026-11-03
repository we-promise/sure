class AddSetupAccountIdToMoomooAccounts < ActiveRecord::Migration[8.1]
  def change
    # The account Sure created for the row (see Account.create_from_moomoo_account).
    add_column :moomoo_accounts, :setup_account_id, :uuid
  end
end
