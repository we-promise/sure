class AddDisplayModeToEtoroAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :etoro_accounts, :display_mode, :string, default: "holdings", null: false
  end
end
