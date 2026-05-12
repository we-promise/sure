class AddManualSyncToSophtronAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :sophtron_accounts, :manual_sync, :boolean, default: false, null: false

    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          UPDATE sophtron_accounts
          SET manual_sync = TRUE
          FROM sophtron_items
          WHERE sophtron_accounts.sophtron_item_id = sophtron_items.id
            AND sophtron_items.manual_sync = TRUE
        SQL
      end
    end
  end
end
