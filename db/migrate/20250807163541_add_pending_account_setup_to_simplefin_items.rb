class AddPendingAccountSetupToSimplefinItems < ActiveRecord::Migration[7.2]
  def change
    add_column :simplefin_items, :pending_account_setup, :boolean, default: false, null: false
  end
end
