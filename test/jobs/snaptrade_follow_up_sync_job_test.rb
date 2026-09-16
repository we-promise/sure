require "test_helper"

class SnaptradeFollowUpSyncJobTest < ActiveJob::TestCase
  test "queues a sync after the active sync has finished" do
    item = snaptrade_items(:configured_item)

    assert_difference "item.syncs.count", 1 do
      SnaptradeFollowUpSyncJob.perform_now(item)
    end
  end

  test "retries while an item sync is in progress" do
    item = snaptrade_items(:configured_item)
    active_sync = item.syncs.create!
    active_sync.start!

    assert_no_difference "item.syncs.count" do
      assert_enqueued_with job: SnaptradeFollowUpSyncJob do
        SnaptradeFollowUpSyncJob.perform_now(item)
      end
    end
  end
end
