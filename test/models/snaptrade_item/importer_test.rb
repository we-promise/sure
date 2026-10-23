require "test_helper"

class SnaptradeItem::ImporterTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @snaptrade_account = snaptrade_accounts(:fidelity_401k)
    @provider = mock("snaptrade_provider")
    @provider.stubs(:get_account_activities).returns([])
    @provider.stubs(:get_activities).returns([])
    @importer = SnaptradeItem::Importer.new(snaptrade_items(:configured_item), snaptrade_provider: @provider)
  end

  # The flag is how anything outside the job chain (the item's syncing state,
  # SnaptradeAccount::SplitSecurityRepair) sees that a fetch is on its way,
  # so the job must never be queued without it.
  test "a fresh account with no activities is flagged and queues a background fetch" do
    assert_not @snaptrade_account.activities_fetch_pending?

    assert_enqueued_with(job: SnaptradeActivitiesFetchJob) do
      @importer.send(:import_activities, @snaptrade_account)
    end

    assert @snaptrade_account.reload.activities_fetch_pending?
  end

  test "no background fetch is queued when the pending flag cannot be set" do
    @snaptrade_account.stubs(:update!).with(activities_fetch_pending: true).raises(ActiveRecord::ActiveRecordError, "boom")

    assert_no_enqueued_jobs(only: SnaptradeActivitiesFetchJob) do
      assert_raises(ActiveRecord::ActiveRecordError) { @importer.send(:import_activities, @snaptrade_account) }
    end
  end

  # Set before the enqueue, the flag would otherwise outlive a fetch that was
  # never queued, holding the item in "syncing" until SyncCleanerJob clears it.
  test "the pending flag is cleared again when queueing the fetch raises" do
    queue = mock("configured_job")
    queue.stubs(:perform_later).raises(RuntimeError, "queue down")
    SnaptradeActivitiesFetchJob.stubs(:set).returns(queue)

    assert_raises(RuntimeError) { @importer.send(:import_activities, @snaptrade_account) }

    assert_not @snaptrade_account.reload.activities_fetch_pending?
  end

  # Active Job reports an adapter's EnqueueError by returning false, not by
  # raising.
  test "the pending flag is cleared again when the queue refuses the fetch" do
    queue = mock("configured_job")
    queue.stubs(:perform_later).returns(false)
    SnaptradeActivitiesFetchJob.stubs(:set).returns(queue)

    @importer.send(:import_activities, @snaptrade_account)

    assert_not @snaptrade_account.reload.activities_fetch_pending?
  end
end
