require "test_helper"

class FollowUpSyncJobTest < ActiveJob::TestCase
  setup do
    @item = plaid_items(:one)
  end

  test "syncs once the running sync has finished" do
    finished = @item.syncs.create!(status: "completed", completed_at: Time.current)

    assert_difference -> { @item.syncs.count }, 1 do
      FollowUpSyncJob.perform_now(@item, active_sync_id: finished.id)
    end
  end

  test "waits while the running sync is still going" do
    running = @item.syncs.create!(status: "syncing")

    assert_no_difference -> { @item.syncs.count } do
      assert_enqueued_with(job: FollowUpSyncJob, args: [ @item, { active_sync_id: running.id, attempts_remaining: FollowUpSyncJob::MAX_ATTEMPTS - 1 } ]) do
        FollowUpSyncJob.perform_now(@item, active_sync_id: running.id)
      end
    end
  end

  test "keeps waiting on a sync that is still running after the reuse window" do
    running = @item.syncs.create!(status: "syncing", created_at: 10.minutes.ago)

    assert_no_difference -> { @item.syncs.count } do
      assert_enqueued_with(job: FollowUpSyncJob) do
        FollowUpSyncJob.perform_now(@item, active_sync_id: running.id)
      end
    end
  end

  test "gives up waiting after the last attempt, records it and syncs anyway" do
    running = @item.syncs.create!(status: "syncing")
    @item.expects(:sync_later).once

    assert_difference -> { DebugLogEntry.count }, 1 do
      FollowUpSyncJob.perform_now(@item, active_sync_id: running.id, attempts_remaining: 0)
    end

    assert_equal "FollowUpSyncJob", DebugLogEntry.order(:created_at).last.source
  end
end
