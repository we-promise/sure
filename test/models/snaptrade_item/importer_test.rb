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
end
