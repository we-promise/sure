class AddEnableBankingSyncCooldown < ActiveRecord::Migration[8.1]
  def change
    add_column :enable_banking_items, :next_sync_at, :datetime
    add_column :enable_banking_items, :sync_retry_count, :integer, null: false, default: 0
    add_column :enable_banking_items, :sync_retry_reason, :string
  end
end
