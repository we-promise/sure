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

  test "a rate-limited Personal key fails the import instead of being swallowed" do
    @provider.stubs(:list_accounts).returns([])
    @provider.stubs(:get_positions).returns([])
    @provider.stubs(:rate_limit_error).returns(Provider::Snaptrade::RateLimitError.new("Rate limit exceeded"))

    assert_raises(Provider::Snaptrade::RateLimitError) { @importer.import }
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

  test "the first background fetch waits the same 15 seconds as its retries" do
    freeze_time do
      assert_enqueued_with(job: SnaptradeActivitiesFetchJob, at: SnaptradeActivitiesFetchJob::RETRY_DELAY.from_now) do
        @importer.send(:import_activities, @snaptrade_account)
      end
    end
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

  # A refused enqueue raises nothing, so support only learns of it from
  # /settings/debug.
  test "a refused fetch is logged against this connection" do
    family = families(:dylan_family)
    account = family.accounts.create!(name: "Linked 401k", balance: 0, currency: "USD", accountable: Investment.new)
    @snaptrade_account.ensure_account_provider!(account)
    @snaptrade_account.reload

    queue = mock("configured_job")
    queue.stubs(:perform_later).returns(false)
    SnaptradeActivitiesFetchJob.stubs(:set).returns(queue)

    assert_difference -> { DebugLogEntry.where(provider_key: "snaptrade", level: "error").count }, 1 do
      @importer.send(:import_activities, @snaptrade_account)
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal [ "SnaptradeItem::Importer", "provider_sync", family, @snaptrade_account.account_provider, @snaptrade_account.id ],
                 [ entry.source, entry.category, entry.family, entry.account_provider, entry.metadata["snaptrade_account_id"] ]
  end

  # An incomplete fetch (the provider's page cap or a missing page) raises, so
  # the stored history and its sync cursor stay as they were.
  test "a fetch that raises keeps the stored activities and the sync cursor" do
    synced_at = 2.days.ago.change(usec: 0)
    stored = Array.new(SnaptradeItem::Importer::MINIMUM_HISTORY_FOR_INCREMENTAL) { |i| { "id" => "a#{i}" } }
    @snaptrade_account.update!(raw_activities_payload: stored, last_activities_sync: synced_at)
    snaptrade_items(:configured_item).update!(last_synced_at: synced_at)
    @provider.stubs(:get_account_activities).raises(Provider::Snaptrade::ApiError.new("hit the page cap"))

    @importer.send(:import_activities, @snaptrade_account)

    @snaptrade_account.reload
    assert_equal stored, @snaptrade_account.raw_activities_payload
    assert_equal synced_at, @snaptrade_account.last_activities_sync
  end

  # A failed fetch is not SnapTrade still syncing: the job would repeat the
  # whole fetch (up to the page cap) only to fail the same way.
  test "a fresh account whose fetch raises is not flagged and queues no background fetch" do
    @provider.stubs(:get_account_activities).raises(Provider::Snaptrade::ApiError.new("hit the page cap"))

    assert_no_enqueued_jobs(only: SnaptradeActivitiesFetchJob) do
      @importer.send(:import_activities, @snaptrade_account)
    end

    assert_not @snaptrade_account.reload.activities_fetch_pending?
  end

  # The liability sign repair only judges history from a fetch that succeeded
  test "a failed activities fetch is recorded, and the next successful one clears it" do
    @provider.stubs(:get_account_activities).raises(Provider::Snaptrade::ApiError.new("hit the page cap"))
    @importer.send(:import_activities, @snaptrade_account)
    assert @snaptrade_account.reload.activities_fetch_failed?

    @provider.stubs(:get_account_activities).returns([])
    @importer.send(:import_activities, @snaptrade_account)
    assert_not @snaptrade_account.reload.activities_fetch_failed?
  end
end
