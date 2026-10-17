class AddSyncStrategyToEnableBankingItems < ActiveRecord::Migration[8.1]
  def up
    add_column :enable_banking_items, :sync_strategy, :string, null: false, default: "date"

    # Existing connections without a configured sync_start_date behave today
    # like the importer's hardcoded 3-month default (see
    # EnableBankingItem::Importer#determine_sync_start_date). Backfilling makes
    # that explicit so the new presence/bounds validation on sync_start_date
    # (added alongside this column, active only when sync_strategy == "date")
    # doesn't reject routine saves of pre-existing rows — e.g. the
    # status: :requires_update update that flags a session as expired.
    execute <<~SQL
      UPDATE enable_banking_items
      SET sync_start_date = (CURRENT_DATE - INTERVAL '3 months')
      WHERE sync_start_date IS NULL
    SQL
  end

  def down
    remove_column :enable_banking_items, :sync_strategy
  end
end
