require "test_helper"

class SyncJobTest < ActiveJob::TestCase
  test "sync is performed" do
    syncable = accounts(:depository)

    sync = syncable.syncs.create!(window_start_date: 2.days.ago.to_date)

    sync.expects(:perform).once

    SyncJob.perform_now(sync)
  end

  test "a follow-up sync waits until the running sync of the same syncable finishes" do
    syncable = accounts(:depository)
    running = syncable.syncs.create!
    running.start!
    follow_up = syncable.syncs.create!(window_start_date: 2.days.ago.to_date)

    follow_up.expects(:perform).never

    assert_enqueued_with job: SyncJob, args: [ follow_up, { balances_only: true } ] do
      SyncJob.perform_now(follow_up, balances_only: true)
    end
    assert follow_up.reload.pending?

    running.update_columns(status: "completed", completed_at: Time.current)
    follow_up.expects(:perform).once
    SyncJob.perform_now(follow_up)
  end

  test "a follow-up sync does not wait for a running sync of another syncable" do
    accounts(:investment).syncs.create!.start!
    sync = accounts(:depository).syncs.create!

    sync.expects(:perform).once

    assert_no_enqueued_jobs only: SyncJob do
      SyncJob.perform_now(sync)
    end
  end
end
