require "test_helper"

class SyncableTest < ActiveSupport::TestCase
  def test_current_sync_maps_avoid_additional_queries
    account = Account.find(accounts(:depository).id)

    sync = Sync.create!(syncable: account)
    sync.start!

    key = [ account.class.base_class.name, account.id ]
    Current.latest_sync_by_syncable = { key => sync }
    Current.latest_completed_sync_by_syncable = {}
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
