require "test_helper"

class SyncableTest < ActiveSupport::TestCase
  def test_current_sync_maps_avoid_additional_queries
    account = Account.find(accounts(:depository).id)

    sync = Sync.create!(syncable: account)
    sync.start!

    key = [ account.class.base_class.name, account.id ]
    Current.latest_sync_by_syncable = { key => sync }
    Current.latest_completed_sync_by_syncable = { key => nil }
    Current.syncing_by_syncable = { key => true }

    queries = capture_sql_queries do
      account.syncing?
      account.last_sync_created_at
      account.last_synced_at
    end

    assert_equal [], queries
  ensure
    Current.reset
  end

  def test_syncing_without_current_maps_queries_database
    account = Account.find(accounts(:depository).id)
    Current.reset

    sync = Sync.create!(syncable: account)
    sync.start!

    queries = capture_sql_queries do
      assert account.syncing?
    end

    assert queries.grep(/FROM "syncs"/).any?,
      "Expected syncing? to query syncs when Current maps are absent"
  ensure
    Current.reset
  end

  def test_latest_completed_sync_without_current_maps_queries_database
    account = Account.find(accounts(:depository).id)
    Current.reset

    sync = Sync.create!(syncable: account, status: :completed)
    sync.update_column(:completed_at, Time.current)

    queries = capture_sql_queries do
      account.last_synced_at
    end

    assert queries.grep(/FROM "syncs"/).any?,
      "Expected latest_completed_sync_record to query syncs when Current maps are absent"
  ensure
    Current.reset
  end

  def test_partial_current_sync_maps_fall_back_to_database
    account = Account.find(accounts(:depository).id)
    Current.reset

    sync = Sync.create!(syncable: account)
    sync.start!

    key = [ account.class.base_class.name, account.id ]
    Current.latest_sync_by_syncable = {}
    Current.latest_completed_sync_by_syncable = {}
    Current.syncing_by_syncable = {}

    queries = capture_sql_queries do
      assert account.syncing?
      assert_equal sync.created_at, account.last_sync_created_at
    end

    assert queries.grep(/FROM "syncs"/).any?,
      "Expected partial Current maps to fall back to database queries"
  ensure
    Current.reset
  end

  private
    def capture_sql_queries
      queries = []

      callback = lambda do |_name, _start, _finish, _message_id, payload|
        sql = payload[:sql].to_s
        name = payload[:name].to_s

        next if name == "SCHEMA"
        next if sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK)\b/i)

        queries << sql
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        yield
      end

      queries
    end
end
