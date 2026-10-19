class AddEnableBankingSyncBudgets < ActiveRecord::Migration[8.1]
  def up
    add_column :enable_banking_items, :last_successful_sync_at, :datetime

    create_table :enable_banking_sync_budgets, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :bank_key, null: false, limit: 64
      t.datetime :next_background_sync_at
      t.datetime :rate_limited_until
      t.datetime :last_data_request_at
      t.uuid :active_sync_id
      t.boolean :active_sync_online, null: false, default: false
      t.timestamps
    end

    add_index :enable_banking_sync_budgets, [ :family_id, :bank_key ], unique: true,
              name: "index_enable_banking_sync_budgets_on_family_and_bank"
    add_index :enable_banking_sync_budgets, :next_background_sync_at
    add_index :enable_banking_sync_budgets, :active_sync_id

    execute <<~SQL
      UPDATE enable_banking_items AS item
      SET last_successful_sync_at = successful_syncs.completed_at
      FROM (
        SELECT syncable_id, MAX(completed_at) AS completed_at
        FROM syncs
        WHERE syncable_type = 'EnableBankingItem'
          AND status = 'completed'
          AND completed_at IS NOT NULL
          AND sync_stats LIKE '%"total_accounts"%'
          AND sync_stats NOT LIKE '%"partial_import":true%'
          AND sync_stats NOT LIKE '%"deferred":true%'
          AND sync_stats NOT LIKE '%"catalog_only":true%'
        GROUP BY syncable_id
      ) AS successful_syncs
      WHERE item.id = successful_syncs.syncable_id
    SQL
  end

  def down
    drop_table :enable_banking_sync_budgets
    remove_column :enable_banking_items, :last_successful_sync_at
  end
end
