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
end
