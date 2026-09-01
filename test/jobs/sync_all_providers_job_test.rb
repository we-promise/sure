require "test_helper"

class SyncAllProvidersJobTest < ActiveJob::TestCase
  test "provider-wide sync requests Plaid transaction refreshes before syncing family" do
    family = families(:dylan_family)

    Family.stubs(:find_by).with(id: family.id).returns(family)
    sequence = sequence("provider-wide sync")
    PlaidItem.any_instance.expects(:request_transactions_refresh_later).in_sequence(sequence)
    family.expects(:sync_later).in_sequence(sequence)

    SyncAllProvidersJob.perform_now(family.id)
  end

  test "provider-wide sync continues when a Plaid refresh cannot be enqueued" do
    family = families(:dylan_family)

    Family.stubs(:find_by).with(id: family.id).returns(family)
    PlaidItem.any_instance.stubs(:request_transactions_refresh_later).raises(RedisClient::Error, "Redis unavailable")
    family.expects(:sync_later)

    assert_difference "DebugLogEntry.count", 1 do
      SyncAllProvidersJob.perform_now(family.id)
    end

    debug_entry = DebugLogEntry.order(:created_at).last
    assert_equal "SyncAllProvidersJob", debug_entry.source
    assert_equal "RedisClient::Error", debug_entry.metadata["error_class"]
  end

  test "provider-wide sync ignores a deleted family" do
    Family.expects(:find_by).returns(nil)

    PlaidItem.any_instance.expects(:request_transactions_refresh_later).never

    SyncAllProvidersJob.perform_now("missing")
  end
end
