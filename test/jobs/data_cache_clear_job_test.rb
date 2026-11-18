require "test_helper"

class DataCacheClearJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @plaid_item = @family.plaid_items.syncable.first
  end

  test "rebuilds through the family sync" do
    @family.expects(:sync_later).once
    PlaidItem.any_instance.expects(:sync_later).never

    DataCacheClearJob.perform_now(@family)
  end

  # The family sync leaves these out, and their accounts were cleared too.
  test "also syncs connections on their own schedule of a day or longer" do
    @plaid_item.create_sync_schedule!(interval_minutes: 10080)

    @family.expects(:sync_later).once
    PlaidItem.any_instance.expects(:sync_later).once

    DataCacheClearJob.perform_now(@family)
  end

  test "leaves connections on a shorter schedule to the family sync" do
    @plaid_item.create_sync_schedule!(interval_minutes: 720)

    @family.expects(:sync_later).once
    PlaidItem.any_instance.expects(:sync_later).never

    DataCacheClearJob.perform_now(@family)
  end

  # The connection's own sync rebuilds its accounts after importing, so
  # they are not rebuilt alongside the import.
  test "leaves the accounts of a day-long connection to that connection's sync" do
    @plaid_item.create_sync_schedule!(interval_minutes: 10080)

    @family.expects(:sync_later).once
    Account.any_instance.expects(:sync_later).never

    DataCacheClearJob.perform_now(@family)
  end

  # A running sync would be reused and may already be past its import.
  test "follows a running sync of a day-long connection with a fresh one" do
    @plaid_item.create_sync_schedule!(interval_minutes: 10080)
    @plaid_item.syncs.create!(status: "syncing")

    @family.expects(:sync_later).once
    PlaidItem.any_instance.expects(:sync_later).never

    assert_enqueued_with(job: FollowUpSyncJob, args: [ @plaid_item ]) do
      DataCacheClearJob.perform_now(@family)
    end
  end

  test "follows an unfinished sync older than the reuse window with a fresh one" do
    @plaid_item.create_sync_schedule!(interval_minutes: 10080)
    @plaid_item.syncs.create!(status: "syncing", created_at: 10.minutes.ago)

    @family.expects(:sync_later).once
    PlaidItem.any_instance.expects(:sync_later).never

    assert_enqueued_with(job: FollowUpSyncJob, args: [ @plaid_item ]) do
      DataCacheClearJob.perform_now(@family)
    end
  end
end
