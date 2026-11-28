class AddScalableCapitalAccountSelection < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  SOURCE_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/

  class ItemRow < ActiveRecord::Base
    self.table_name = "scalable_capital_items"
  end

  class AccountRow < ActiveRecord::Base
    self.table_name = "scalable_capital_accounts"
  end

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
      execute "LOCK TABLE scalable_capital_items, scalable_capital_accounts IN ACCESS EXCLUSIVE MODE"
      legacy_updates.each { |item, attributes| item.update_columns(attributes) }

      remove_index :scalable_capital_accounts, name: "index_scalable_capital_accounts_on_source"
      add_index :scalable_capital_accounts, [ :scalable_capital_item_id, :kind ],
                unique: true, name: "index_scalable_capital_accounts_on_item_and_kind"
      remove_column :scalable_capital_accounts, :source_key
      remove_columns :scalable_capital_items, :selected_sources, :broker_history_version
      change_column_null :scalable_capital_items, :portfolio_id, false
    end
  end

  private

    def legacy_updates
      if AccountRow.group(:scalable_capital_item_id, :kind).having("COUNT(*) > 1").exists?
        refuse_rollback!("a connection has multiple accounts of the same kind")
      end

      updates = []
      ItemRow.find_each do |item|
        accounts = AccountRow.where(scalable_capital_item_id: item.id).pluck(:kind, :source_key)
        if item.selected_sources == []
          unless valid_source_id?(item.portfolio_id) && (item.savings_id.nil? || valid_source_id?(item.savings_id)) &&
                 accounts.all? { |_, key| key.nil? }
            refuse_rollback!("a legacy connection has missing identifiers or source-specific accounts")
          end
        else
          updates << [ item, legacy_selection(item, accounts) ]
        end
      end
      updates
    end

    def legacy_selection(item, accounts)
      sources = item.selected_sources
      unless sources.is_a?(Array) && sources.size == 2 && sources.all? { |source| source.is_a?(Hash) && valid_source_id?(source["id"]) }
        refuse_rollback!("the account picker selection is not one brokerage and one personal Overnight Savings account")
      end

      brokerage, savings = sources.index_by { |source| source["kind"] }.values_at("brokerage", "savings")
      unless brokerage&.fetch("owner_kind", "personal") == "personal" && savings&.fetch("owner_kind", nil) == "personal"
        refuse_rollback!("the account picker selection is not one brokerage and one personal Overnight Savings account")
      end

      # An empty legacy savings ID discovers savings implicitly, so a brokerage-only
      # selection cannot be represented without expanding what the connection syncs.
      attributes = {
        portfolio_id: brokerage.fetch("id"),
        savings_id: savings.fetch("id"),
        broker_synced_through: checkpoint(brokerage),
        savings_synced_through: checkpoint(savings)
      }
      if attributes.any? { |field, value| !item[field].nil? && item[field] != value }
        refuse_rollback!("a connection has conflicting legacy account identifiers or checkpoints")
      end

      expected_keys = {
        "brokerage" => "brokerage:#{attributes[:portfolio_id]}",
        "cash" => "brokerage:#{attributes[:portfolio_id]}",
        "savings" => "savings:#{attributes[:savings_id]}"
      }
      unless accounts.all? { |kind, key| key.present? && key == expected_keys[kind] }
        refuse_rollback!("a linked account cannot be matched to the selected brokerage or savings account")
      end

      attributes
    end

    def checkpoint(source)
      value = source["synced_through"]
      return if value.nil?

      Time.iso8601(value)
    rescue ArgumentError, TypeError
      refuse_rollback!("a selected account has an invalid sync checkpoint")
    end

    def valid_source_id?(value)
      value.is_a?(String) && SOURCE_ID_PATTERN.match?(value)
    end

    def refuse_rollback!(reason)
      raise ActiveRecord::IrreversibleMigration,
            "Cannot roll back Scalable Capital account selection because #{reason}. " \
            "Keep the current Sure version, or restore a pre-upgrade database backup with its matching Sure version in a separate instance."
    end

    def backfill_entries_excluded_if_preview_used_its_version
      return unless column_exists?(:entries, :excluded, :boolean, null: true)
      return unless connection.select_value("SELECT 1 FROM schema_migrations WHERE version = '20261126100000'")

      # A preview may have recorded this version for account selection. Replay
      # the upstream backfill outside a transaction before its constraint is validated.
      require_relative "20261126100000_backfill_entries_excluded"
      BackfillEntriesExcluded.new.exec_migration(connection, :up)
    end
end
