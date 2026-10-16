# Lets a user show the Brandfetch logo while keeping a fetched or uploaded icon
# to switch back to. An attached logo otherwise wins over Brandfetch.
class AddPreferBrandfetchLogoToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :prefer_brandfetch_logo, :boolean, default: false, null: false, if_not_exists: true
  end
end
