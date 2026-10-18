class AddDirectaHistorySyncState < ActiveRecord::Migration[8.1]
  def change
    add_column :directa_accounts, :history_ledger, :jsonb
    add_column :directa_accounts, :history_synced_at, :datetime
    add_column :directa_items, :history_sync_error_code, :string
  end
end
