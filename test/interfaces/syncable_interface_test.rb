require "test_helper"

module SyncableInterfaceTest
  extend ActiveSupport::Testing::Declarative
  include ActiveJob::TestHelper

  test "can sync later" do
    assert_difference "@syncable.syncs.count", 1 do
      assert_enqueued_with job: SyncJob do
        @syncable.sync_later(window_start_date: 2.days.ago.to_date)
      end
    end
  end

  test "can perform sync" do
    mock_sync = mock
    @syncable.class.any_instance.expects(:perform_sync).with(mock_sync).once
    @syncable.perform_sync(mock_sync)
  end

  test "sync_later does not enqueue SyncJob while a surrounding transaction is still open" do
    job_enqueued_mid_transaction = false

    ActiveRecord::Base.transaction do
      @syncable.sync_later
      job_enqueued_mid_transaction = queue_adapter.enqueued_jobs.any? { |j| j[:job] == SyncJob }
    end

    assert_not job_enqueued_mid_transaction, "SyncJob was enqueued inside an open transaction (GlobalID race)"
    assert_enqueued_with(job: SyncJob)
  end

  test "second sync request widens existing pending window" do
    later_start = 2.days.ago.to_date
    first_sync = @syncable.sync_later(window_start_date: later_start, window_end_date: later_start)

    earlier_start = 5.days.ago.to_date
    wider_end     = Date.current

    assert_no_difference "@syncable.syncs.count" do
      @syncable.sync_later(window_start_date: earlier_start, window_end_date: wider_end)
    end

    first_sync.reload
    assert_equal earlier_start, first_sync.window_start_date
    assert_equal wider_end, first_sync.window_end_date
  end

  test "sync request during a running sync queues a follow-up sync" do
    running = @syncable.sync_later
    running.start!

    follow_up = nil
    assert_difference "@syncable.syncs.count", 1 do
      assert_enqueued_with job: SyncJob do
        follow_up = @syncable.sync_later
      end
    end

    assert_not_equal running.id, follow_up.id
    assert follow_up.pending?
  end

  test "sync requests during a running sync share one follow-up sync" do
    running = @syncable.sync_later
    running.start!

    start = 2.days.ago.to_date
    follow_up = @syncable.sync_later(window_start_date: start, window_end_date: start)

    assert_no_difference "@syncable.syncs.count" do
      assert_equal follow_up, @syncable.sync_later(window_start_date: 5.days.ago.to_date, window_end_date: start)
    end
    assert_equal 5.days.ago.to_date, follow_up.reload.window_start_date
  end
end
