require "test_helper"

class SyncScheduledItemsJobTest < ActiveJob::TestCase
  setup do
    @plaid_item = plaid_items(:one)
    @wise_item = wise_items(:one)
  end

  test "syncs the connections whose schedule is due and advances them" do
    schedule = due_schedule(@plaid_item)

    assert_difference -> { @plaid_item.syncs.count }, 1 do
      SyncScheduledItemsJob.perform_now
    end

    assert_enqueued_with(job: SyncJob)
    assert_operator schedule.reload.next_run_at, :>, Time.current
  end

  test "a Plaid connection is asked to refresh, as every other sync entry point does" do
    due_schedule(@plaid_item)
    PlaidItem.any_instance.expects(:sync_later_with_provider_refresh).once

    SyncScheduledItemsJob.perform_now
  end

  test "does not sync a schedule that is no longer due once locked" do
    due_schedule(@plaid_item)
    SyncSchedule.any_instance.stubs(:advance!).returns(false)

    assert_no_difference -> { @plaid_item.syncs.count } do
      SyncScheduledItemsJob.perform_now
    end
  end

  test "leaves schedules that are not yet due alone" do
    schedule = @plaid_item.create_sync_schedule!(interval_minutes: 720)

    assert_no_difference -> { @plaid_item.syncs.count } do
      SyncScheduledItemsJob.perform_now
    end

    assert_equal schedule.next_run_at, schedule.reload.next_run_at
  end

  # A connection on its way out, or otherwise outside the class's `syncable`
  # scope, is skipped the same way the daily family sync skips it.
  test "skips connections the provider no longer syncs" do
    schedule = due_schedule(@plaid_item)
    @plaid_item.update_column(:scheduled_for_deletion, true)

    assert_no_difference -> { @plaid_item.syncs.count } do
      SyncScheduledItemsJob.perform_now
    end

    assert_operator schedule.reload.next_run_at, :>, Time.current
  end

  test "drops a schedule whose connection is gone" do
    schedule = due_schedule(@plaid_item)
    schedule.update_columns(syncable_id: SecureRandom.uuid)

    SyncScheduledItemsJob.perform_now

    assert_not SyncSchedule.exists?(schedule.id)
  end

  test "drops a schedule whose provider no longer exists" do
    schedule = due_schedule(@plaid_item)
    schedule.update_columns(syncable_type: "RetiredProviderItem")

    assert_nothing_raised { SyncScheduledItemsJob.perform_now }

    assert_not SyncSchedule.exists?(schedule.id)
  end

  test "keeps going when one connection fails to sync, and records the failure for support" do
    due_schedule(@plaid_item)
    due_schedule(@wise_item)
    PlaidItem.any_instance.stubs(:sync_later_with_provider_refresh).raises(StandardError, "boom")

    assert_difference -> { @wise_item.syncs.count }, 1 do
      assert_nothing_raised { SyncScheduledItemsJob.perform_now }
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal [ "provider_sync", "error", "SyncScheduledItemsJob", "plaid" ], [ entry.category, entry.level, entry.source, entry.provider_key ]
    assert_equal @plaid_item.family, entry.family
    assert_equal({ "syncable_type" => "PlaidItem", "syncable_id" => @plaid_item.id, "error_class" => "StandardError" }, entry.metadata)
  end

  test "a run whose sync could not be started stays due for the next tick" do
    schedule = due_schedule(@plaid_item)
    schedule.update!(interval_minutes: 20160)
    due_at = 1.minute.ago.change(usec: 0)
    schedule.update_column(:next_run_at, due_at)
    PlaidItem.any_instance.stubs(:sync_later_with_provider_refresh).raises(RedisClient::CannotConnectError, "queue down")

    assert_nothing_raised { SyncScheduledItemsJob.perform_now }

    assert_equal due_at, schedule.reload.next_run_at
    assert_includes SyncSchedule.due, schedule
  end

  test "a run whose sync started moves on to the next interval" do
    schedule = due_schedule(@plaid_item)
    schedule.update!(interval_minutes: 20160)
    schedule.update_column(:next_run_at, 1.minute.ago)

    SyncScheduledItemsJob.perform_now

    assert_operator schedule.reload.next_run_at, :>, Time.current
  end

  private
    def due_schedule(item)
      item.create_sync_schedule!(interval_minutes: 15).tap do |schedule|
        schedule.update_column(:next_run_at, 1.minute.ago)
      end
    end
end
