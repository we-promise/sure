class AddFinecoHistorySyncState < ActiveRecord::Migration[8.1]
  def change
    add_column :fineco_accounts, :history_ledger, :jsonb
    add_column :fineco_accounts, :history_synced_at, :datetime
    add_column :fineco_items, :history_sync_error_code, :string
  end
end
