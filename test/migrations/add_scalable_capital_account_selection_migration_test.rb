# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261126095959_add_scalable_capital_account_selection")
require Rails.root.join("db/migrate/20261126100000_backfill_entries_excluded")
require Rails.root.join("db/migrate/20261126100100_make_entries_excluded_not_null")

class AddScalableCapitalAccountSelectionMigrationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  SELECTION_VERSION = 20261126095959
  BACKFILL_VERSION = 20261126100000
  CONSTRAINT_VERSION = 20261126100100

  test "a regular Sure upgrade runs both the account selection and entries migrations" do
    roll_back_account_selection
    entry = make_nullable_entry

    migrate_pending(SELECTION_VERSION, BACKFILL_VERSION, CONSTRAINT_VERSION)

    assert_equal false, stored_excluded(entry)
    assert connection.column_exists?(:entries, :excluded, :boolean, null: false)
    assert connection.column_exists?(:scalable_capital_items, :portfolio_id, :string, null: true)
    assert connection.column_exists?(:scalable_capital_items, :selected_sources, :jsonb)
    assert connection.column_exists?(:scalable_capital_accounts, :source_key, :string)
  end

  test "an existing preview retains its sync state and runs the skipped entries backfill" do
    sources = [
      { "id" => "first-broker", "kind" => "brokerage" },
      { "id" => "second-broker", "kind" => "brokerage" }
    ]
    checkpoint = 2.days.ago.change(usec: 0)
    item = ScalableCapitalItem.create!(
      family: families(:dylan_family), selected_sources: sources,
      broker_synced_through: checkpoint, broker_history_version: 1, import_generation: 7
    )
    keys = sources.map { |source| source.fetch("id") }
    keys.each { |key| item.scalable_capital_accounts.create!(kind: :brokerage, source_key: key) }
    entry = make_nullable_entry
    assert_includes connection.pool.schema_migration.integer_versions, BACKFILL_VERSION

    migrate_pending(SELECTION_VERSION, CONSTRAINT_VERSION)

    assert_equal false, stored_excluded(entry)
    assert connection.column_exists?(:entries, :excluded, :boolean, null: false)
    assert_equal sources, item.reload.selected_sources
    assert_equal checkpoint, item.broker_synced_through
    assert_equal 1, item.broker_history_version
    assert_equal 7, item.import_generation
    assert_equal keys, item.scalable_capital_accounts.order(:source_key).pluck(:source_key)
  end

  test "an already upgraded Sure database keeps its entries constraint when adding account selection" do
    roll_back_account_selection

    migrate_pending(SELECTION_VERSION)

    assert connection.column_exists?(:entries, :excluded, :boolean, null: false)
    refute connection.check_constraint_exists?(:entries, name: "chk_entries_excluded_not_null")
    assert connection.column_exists?(:scalable_capital_items, :selected_sources, :jsonb)
  end

  test "rollback converts a compatible selection and preserves both checkpoints and account links" do
    broker_checkpoint = Time.utc(2026, 11, 20, 12)
    savings_checkpoint = Time.utc(2026, 11, 21, 13)
    sources = [
      { "kind" => "brokerage", "id" => "broker-one", "synced_through" => broker_checkpoint.iso8601 },
      { "kind" => "savings", "id" => "personal-savings", "owner_kind" => "personal", "synced_through" => savings_checkpoint.iso8601 }
    ]
    item = families(:dylan_family).scalable_capital_items.create!(selected_sources: sources, broker_account_id: "person")
    account_links = { brokerage: "brokerage:broker-one", cash: "brokerage:broker-one", savings: "savings:personal-savings" }.map do |kind, key|
      source = item.scalable_capital_accounts.create!(kind: kind, source_key: key)
      source.create_linked_account!(balance: 100, cash_balance: 0)
      [ source.id, source.account.id ]
    end.to_h

    roll_back_account_selection

    legacy = item.reload
    assert_equal "broker-one", legacy.portfolio_id
    assert_equal "personal-savings", legacy.savings_id
    assert_equal broker_checkpoint, legacy.broker_synced_through
    assert_equal savings_checkpoint, legacy.savings_synced_through
    assert_equal "person", legacy.broker_account_id
    assert_equal account_links, AccountProvider.where(provider_type: "ScalableCapitalAccount", provider_id: account_links.keys)
      .pluck(:provider_id, :account_id).to_h
    assert connection.index_exists?(:scalable_capital_accounts, [ :scalable_capital_item_id, :kind ], unique: true)
    assert connection.column_exists?(:scalable_capital_items, :portfolio_id, :string, null: false)
  end

  test "rollback blocks duplicate account kinds before changing the schema or selections" do
    keys = %w[brokerage:first-broker brokerage:second-broker]
    sources = keys.map { |key| { "id" => key.split(":").last, "kind" => "brokerage" } }
    item = families(:dylan_family).scalable_capital_items.create!(selected_sources: sources)
    keys.each { |key| item.scalable_capital_accounts.create!(kind: :brokerage, source_key: key) }

    error = assert_raises(ActiveRecord::IrreversibleMigration) { roll_back_account_selection }

    assert_match "multiple accounts of the same kind", error.message
    assert_equal sources, item.reload.selected_sources
    assert_equal keys, item.scalable_capital_accounts.order(:source_key).pluck(:source_key)
    assert connection.index_exists?(:scalable_capital_accounts, [ :scalable_capital_item_id, :kind, :source_key ], unique: true)
  end

  test "rollback blocks a brokerage-only selection instead of automatically syncing savings" do
    sources = [ { "kind" => "brokerage", "id" => "broker-one" } ]
    item = families(:dylan_family).scalable_capital_items.create!(selected_sources: sources)
    account = item.scalable_capital_accounts.create!(kind: :brokerage, source_key: "brokerage:broker-one")

    error = assert_raises(ActiveRecord::IrreversibleMigration) { roll_back_account_selection }

    assert_match "restore a pre-upgrade database backup", error.message
    assert_nil item.reload.portfolio_id
    assert_equal sources, item.selected_sources
    assert_equal "brokerage:broker-one", account.reload.source_key
    assert connection.column_exists?(:scalable_capital_items, :portfolio_id, :string, null: true)
  end

  test "rollback blocks a junior savings account even when the brokerage fits" do
    sources = [
      { "kind" => "brokerage", "id" => "broker-one" },
      { "kind" => "savings", "id" => "junior-savings", "owner_kind" => "junior" }
    ]
    item = families(:dylan_family).scalable_capital_items.create!(selected_sources: sources)

    assert_raises(ActiveRecord::IrreversibleMigration) { roll_back_account_selection }
    assert_equal sources, item.reload.selected_sources
  end

  private

    def connection = ActiveRecord::Base.connection

    def roll_back_account_selection
      ActiveRecord::Migration.suppress_messages { AddScalableCapitalAccountSelection.new.exec_migration(connection, :down) }
    end

    def make_nullable_entry
      ActiveRecord::Migration.suppress_messages do
        MakeEntriesExcludedNotNull.new.exec_migration(connection, :down)
        BackfillEntriesExcluded.new.exec_migration(connection, :down)
      end
      entry = create_transaction(account: accounts(:depository), name: "Legacy blank exclusion")
      connection.execute("UPDATE entries SET excluded = NULL WHERE id = #{connection.quote(entry.id)}")
      entry
    end

    def stored_excluded(entry)
      connection.select_value("SELECT excluded FROM entries WHERE id = #{connection.quote(entry.id)}")
    end

    def migrate_pending(*versions)
      versions.each { |version| connection.pool.schema_migration.delete_version(version.to_s) }
      context = connection.pool.migration_context
      assert_equal versions, context.pending_migration_versions
      ActiveRecord::Migration.suppress_messages { context.migrate }
      assert_empty context.pending_migration_versions
    end
end
