require "test_helper"

class MarketDataRefreshJobTest < ActiveJob::TestCase
  test "syncs every account across all families" do
    other_family = Family.create!(name: "Other family", currency: "USD")
    other_family.accounts.create!(name: "Other checking", balance: 100, currency: "USD", accountable: Depository.new)

    MarketDataRefreshJob.perform_now

    assert_enqueued_jobs Account.count, only: SyncJob
    assert_no_enqueued_jobs only: MarketDataRefreshJob
  end

  test "syncs linked accounts directly instead of through their provider item" do
    linked = Account.where.not(id: Account.manual.select(:id)).first
    assert linked, "fixtures should include a linked account"

    MarketDataRefreshJob.perform_now

    assert linked.syncs.visible.exists?
  end

  test "retries accounts whose sync has already started" do
    running = accounts(:depository)
    running.syncs.create!(status: "syncing")

    MarketDataRefreshJob.perform_now

    assert_equal 1, running.syncs.visible.count, "a running sync is not reused"
    assert_enqueued_jobs Account.count - 1, only: SyncJob
    assert_enqueued_with job: MarketDataRefreshJob,
      args: [ [ running.id ], { attempts_remaining: MarketDataRefreshJob::MAX_ATTEMPTS - 1 } ]
  end

  test "retries accounts whose sync started longer ago than the visible window" do
    running = accounts(:depository)
    running.syncs.create!(status: "syncing", created_at: (Sync::VISIBLE_FOR + 1.minute).ago)

    MarketDataRefreshJob.perform_now

    assert_equal 1, running.syncs.incomplete.count, "no concurrent sync is created"
    assert_enqueued_with job: MarketDataRefreshJob,
      args: [ [ running.id ], { attempts_remaining: MarketDataRefreshJob::MAX_ATTEMPTS - 1 } ]
  end

  test "retries and logs accounts whose sync could not be queued" do
    account = accounts(:depository)
    Account.any_instance.stubs(:sync_later).raises(StandardError, "queue unavailable")

    assert_difference -> { DebugLogEntry.where(source: "MarketDataRefreshJob", level: "error", account: account).count }, 1 do
      MarketDataRefreshJob.perform_now([ account.id ])
    end

    assert_enqueued_with job: MarketDataRefreshJob,
      args: [ [ account.id ], { attempts_remaining: MarketDataRefreshJob::MAX_ATTEMPTS - 1 } ]
  end

  test "folds into a sync that has not started yet" do
    account = accounts(:depository)
    pending = account.syncs.create!

    MarketDataRefreshJob.perform_now

    assert_equal [ pending ], account.syncs.visible.to_a
    assert_no_enqueued_jobs only: MarketDataRefreshJob
  end

  test "stops retrying after the last attempt" do
    running = accounts(:depository)
    running.syncs.create!(status: "syncing")

    assert_difference -> { DebugLogEntry.where(source: "MarketDataRefreshJob", level: "warn", account: running).count }, 1 do
      MarketDataRefreshJob.perform_now([ running.id ], attempts_remaining: 0)
    end

    assert_no_enqueued_jobs
  end
end
