require "test_helper"

class FollowUpSyncJobTest < ActiveJob::TestCase
  setup do
    @item = plaid_items(:one)
  end

  test "syncs once no sync is left unfinished" do
    @item.syncs.create!(status: "completed", completed_at: Time.current)

    assert_difference -> { @item.syncs.count }, 1 do
      FollowUpSyncJob.perform_now(@item)
    end
  end

  test "waits while a sync is still going" do
    @item.syncs.create!(status: "syncing")

    assert_no_difference -> { @item.syncs.count } do
      assert_enqueued_with(job: FollowUpSyncJob, args: [ @item, { attempts_remaining: FollowUpSyncJob::MAX_ATTEMPTS - 1 } ]) do
        FollowUpSyncJob.perform_now(@item)
      end
    end
  end

  test "keeps waiting on a sync that is still running after the reuse window" do
    @item.syncs.create!(status: "syncing", created_at: 10.minutes.ago)

    assert_no_difference -> { @item.syncs.count } do
      assert_enqueued_with(job: FollowUpSyncJob) { FollowUpSyncJob.perform_now(@item) }
    end
  end

  # Watching only one sync would start a new one while the older still runs.
  test "keeps waiting while an older sync is unfinished after a newer one finished" do
    @item.syncs.create!(status: "syncing", created_at: 20.minutes.ago)
    @item.syncs.create!(status: "completed", completed_at: Time.current)

    assert_no_difference -> { @item.syncs.count } do
      assert_enqueued_with(job: FollowUpSyncJob) { FollowUpSyncJob.perform_now(@item) }
    end
  end

  test "after the last attempt it records the wait and starts no overlapping sync" do
    @item.syncs.create!(status: "syncing", created_at: 2.hours.ago)

    assert_no_difference -> { @item.syncs.count } do
      assert_no_enqueued_jobs(only: FollowUpSyncJob) do
        assert_difference -> { DebugLogEntry.count }, 1 do
          FollowUpSyncJob.perform_now(@item, attempts_remaining: 0)
        end
      end
    end

    assert_equal "FollowUpSyncJob", DebugLogEntry.order(:created_at).last.source
  end
end
