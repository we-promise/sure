require "test_helper"

class SyncAllJobTest < ActiveJob::TestCase
  test "scheduled sync requests Plaid transaction refreshes before syncing families" do
    family = families(:dylan_family)
    Family.stubs(:find_each).yields(family)
    sequence = sequence("scheduled sync")
    PlaidItem.any_instance.expects(:request_transactions_refresh_later).in_sequence(sequence)
    family.expects(:sync_later).in_sequence(sequence)

    SyncAllJob.perform_now
  end

  test "scheduled sync continues when a Plaid refresh cannot be enqueued" do
    family = families(:dylan_family)
    Family.stubs(:find_each).yields(family)
    PlaidItem.any_instance.stubs(:request_transactions_refresh_later).raises(RedisClient::Error, "Redis unavailable")
    family.expects(:sync_later)

    assert_difference "DebugLogEntry.count", 1 do
      SyncAllJob.perform_now
    end

    debug_entry = DebugLogEntry.order(:created_at).last
    assert_equal "SyncAllJob", debug_entry.source
    assert_equal "RedisClient::Error", debug_entry.metadata["error_class"]
  end
end
