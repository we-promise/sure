require "test_helper"

class SyncJobTest < ActiveJob::TestCase
  test "sync is performed" do
    syncable = accounts(:depository)

    sync = syncable.syncs.create!(window_start_date: 2.days.ago.to_date)

    sync.expects(:perform).once

    SyncJob.perform_now(sync)
  end

  test "re-enqueues with the same arguments while another sync of the syncable runs" do
    sync = accounts(:depository).syncs.create!

    sync.expects(:perform).raises(Sync::ConcurrentSyncError)

    assert_enqueued_with(job: SyncJob, args: [ sync, { balances_only: true } ]) do
      SyncJob.perform_now(sync, balances_only: true)
    end
  end

  test "stamps each attempt on a pending sync so later requests can join it" do
    sync = accounts(:depository).syncs.create!
    sync.expects(:perform).raises(Sync::ConcurrentSyncError)

    freeze_time do
      SyncJob.perform_now(sync)
      assert_equal Time.current, sync.reload.last_attempted_at
    end
  end

  test "reports a sync that has waited on another sync for over an hour" do
    sync = accounts(:depository).syncs.create!(created_at: 2.hours.ago)
    sync.stubs(:perform).raises(Sync::ConcurrentSyncError)

    job = SyncJob.new(sync)
    job.executions = SyncJob::LONG_WAIT_REPORT_EVERY - 1

    assert_difference "DebugLogEntry.count", 1 do
      job.perform_now
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "sync", entry.category
    assert_equal "warn", entry.level
    assert_equal "SyncJob", entry.source
    assert_equal accounts(:depository).family, entry.family
    assert_equal sync.id, entry.metadata["sync_id"]
  end

  test "does not report long waits on every retry" do
    sync = accounts(:depository).syncs.create!(created_at: 2.hours.ago)
    sync.stubs(:perform).raises(Sync::ConcurrentSyncError)

    job = SyncJob.new(sync)
    job.executions = SyncJob::LONG_WAIT_REPORT_EVERY

    assert_no_difference "DebugLogEntry.count" do
      job.perform_now
    end
  end

  test "does not report a sync that has only waited briefly" do
    sync = accounts(:depository).syncs.create!
    sync.stubs(:perform).raises(Sync::ConcurrentSyncError)

    job = SyncJob.new(sync)
    job.executions = SyncJob::LONG_WAIT_REPORT_EVERY - 1

    assert_no_difference "DebugLogEntry.count" do
      job.perform_now
    end
  end
end
