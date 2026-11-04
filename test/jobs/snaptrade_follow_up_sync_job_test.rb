require "test_helper"

class SnaptradeFollowUpSyncJobTest < ActiveJob::TestCase
  test "a job queued before follow-ups were built in still requests a sync" do
    item = snaptrade_items(:configured_item)
    item.expects(:sync_later).once

    SnaptradeFollowUpSyncJob.perform_now(item, attempts_remaining: 30)
  end
end
