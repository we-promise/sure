class AddScalableCapitalAccountSelection < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    backfill_entries_excluded_if_preview_used_its_version

    connection.transaction do
      if column_exists?(:scalable_capital_items, :portfolio_id, :string, null: false)
        change_column_null :scalable_capital_items, :portfolio_id, true
      end
      add_column :scalable_capital_items, :selected_sources, :jsonb, default: [], null: false, if_not_exists: true
      add_column :scalable_capital_items, :broker_history_version, :integer, default: 0, null: false, if_not_exists: true
      add_column :scalable_capital_accounts, :source_key, :string, if_not_exists: true

      remove_index :scalable_capital_accounts, name: "index_scalable_capital_accounts_on_item_and_kind", if_exists: true
      add_index :scalable_capital_accounts, [ :scalable_capital_item_id, :kind, :source_key ],
                unique: true, nulls_not_distinct: true, name: "index_scalable_capital_accounts_on_source", if_not_exists: true
    end
  end

  def down
    connection.transaction do
      remove_index :scalable_capital_accounts, name: "index_scalable_capital_accounts_on_source"
      add_index :scalable_capital_accounts, [ :scalable_capital_item_id, :kind ],
                unique: true, name: "index_scalable_capital_accounts_on_item_and_kind"
      remove_column :scalable_capital_accounts, :source_key
      remove_columns :scalable_capital_items, :selected_sources, :broker_history_version
      change_column_null :scalable_capital_items, :portfolio_id, false
    end
  end

  private

    def backfill_entries_excluded_if_preview_used_its_version
      return unless column_exists?(:entries, :excluded, :boolean, null: true)
      return unless connection.select_value("SELECT 1 FROM schema_migrations WHERE version = '20261126100000'")

      # A preview may have recorded this version for account selection. Replay
      # the upstream backfill outside a transaction before its constraint is validated.
      require_relative "20261126100000_backfill_entries_excluded"
      BackfillEntriesExcluded.new.exec_migration(connection, :up)
    end
end
