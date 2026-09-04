class AddLogoSourceToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :logo_source, :string, default: "auto"
  end
end
