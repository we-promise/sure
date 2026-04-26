class AddSkippedToGocardlessAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :gocardless_accounts, :skipped, :boolean, default: false, null: false, if_not_exists: true
    add_index  :gocardless_accounts, :skipped, if_not_exists: true
  end
end
