require "test_helper"

class PlaidTransactionsRefreshFollowUpSyncJobTest < ActiveJob::TestCase
  test "queues a distinct sync after the active sync has finished" do
    item = plaid_items(:one)

    assert_difference "item.syncs.count", 1 do
      PlaidTransactionsRefreshFollowUpSyncJob.perform_now(item)
    end
  end

  test "retries while an item sync is in progress" do
    item = plaid_items(:one)
    active_sync = item.syncs.create!
    active_sync.start!

    assert_no_difference "item.syncs.count" do
      assert_enqueued_with job: PlaidTransactionsRefreshFollowUpSyncJob do
        PlaidTransactionsRefreshFollowUpSyncJob.perform_now(item)
      end
    end
  end

  test "records exhausted retries and still hands off to sync_later" do
    item = plaid_items(:one)
    active_sync = item.syncs.create!
    active_sync.start!
    item.expects(:sync_later).once

    assert_difference "DebugLogEntry.count", 1 do
      PlaidTransactionsRefreshFollowUpSyncJob.perform_now(item, attempts_remaining: 0)
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "provider_sync", entry.category
    assert_equal "PlaidTransactionsRefreshFollowUpSyncJob", entry.source
    assert_equal item.family, entry.family
  end
end
