class AddIgnoredToSimplefinAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :simplefin_accounts, :ignored, :boolean, default: false, null: false
  end
end
