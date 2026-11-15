require "test_helper"

class MarketDataRefreshJobTest < ActiveJob::TestCase
  setup { freeze_time }

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
      args: [ [ running.id ], { attempt: 1, first_attempt_at: Time.current } ]
  end

  test "retries accounts whose sync started longer ago than the visible window" do
    running = accounts(:depository)
    running.syncs.create!(status: "syncing", created_at: (Sync::VISIBLE_FOR + 1.minute).ago)

    MarketDataRefreshJob.perform_now

    assert_equal 1, running.syncs.incomplete.count, "no concurrent sync is created"
    assert_enqueued_with job: MarketDataRefreshJob,
      args: [ [ running.id ], { attempt: 1, first_attempt_at: Time.current } ]
  end

  test "retries and logs accounts whose sync could not be queued" do
    account = accounts(:depository)
    Account.any_instance.stubs(:sync_later).raises(StandardError, "queue unavailable")

    assert_difference -> { DebugLogEntry.where(source: "MarketDataRefreshJob", level: "error", account: account).count }, 1 do
      MarketDataRefreshJob.perform_now([ account.id ])
    end

    assert_enqueued_with job: MarketDataRefreshJob,
      args: [ [ account.id ], { attempt: 1, first_attempt_at: Time.current } ]
  end

  test "folds into a sync that has not started yet" do
    account = accounts(:depository)
    pending = account.syncs.create!

    MarketDataRefreshJob.perform_now

    assert_equal [ pending ], account.syncs.visible.to_a
    assert_no_enqueued_jobs only: MarketDataRefreshJob
  end

  test "backs off between retries up to the maximum delay" do
    running = accounts(:depository)
    running.syncs.create!(status: "syncing")

    MarketDataRefreshJob.perform_now([ running.id ], attempt: 2, first_attempt_at: 10.minutes.ago)
    assert_enqueued_with job: MarketDataRefreshJob, at: 2.minutes.from_now,
      args: [ [ running.id ], { attempt: 3, first_attempt_at: 10.minutes.ago } ]

    MarketDataRefreshJob.perform_now([ running.id ], attempt: 10, first_attempt_at: 10.hours.ago)
    assert_enqueued_with job: MarketDataRefreshJob, at: MarketDataRefreshJob::MAX_RETRY_DELAY.from_now,
      args: [ [ running.id ], { attempt: 11, first_attempt_at: 10.hours.ago } ]
  end

  test "keeps waiting on a running sync until the wait limit" do
    running = accounts(:depository)
    running.syncs.create!(status: "syncing", created_at: 20.hours.ago)

    MarketDataRefreshJob.perform_now([ running.id ], attempt: 50, first_attempt_at: 20.hours.ago)

    assert_equal 1, running.syncs.incomplete.count
    assert_enqueued_with job: MarketDataRefreshJob,
      args: [ [ running.id ], { attempt: 51, first_attempt_at: 20.hours.ago } ]
  end

  test "queues a fresh sync once a running sync outlasts the wait limit" do
    running = accounts(:depository)
    running.syncs.create!(status: "syncing", created_at: (MarketDataRefreshJob::WAIT_LIMIT + 1.minute).ago)

    assert_difference -> { DebugLogEntry.where(source: "MarketDataRefreshJob", level: "warn", account: running).count }, 1 do
      MarketDataRefreshJob.perform_now([ running.id ], attempt: 99, first_attempt_at: MarketDataRefreshJob::WAIT_LIMIT.ago)
    end

    assert running.syncs.visible.exists?, "a fresh sync is queued"
    assert_enqueued_jobs 1, only: SyncJob
    assert_no_enqueued_jobs only: MarketDataRefreshJob
  end

  test "stops retrying a sync that cannot be queued after the wait limit" do
    account = accounts(:depository)
    Account.any_instance.stubs(:sync_later).raises(StandardError, "queue unavailable")

    assert_difference -> { DebugLogEntry.where(source: "MarketDataRefreshJob", level: "warn", account: account).count }, 1 do
      MarketDataRefreshJob.perform_now([ account.id ], attempt: 99, first_attempt_at: MarketDataRefreshJob::WAIT_LIMIT.ago)
    end

    assert_no_enqueued_jobs only: MarketDataRefreshJob
  end

  test "refresh_later logs instead of raising when the queue is down" do
    MarketDataRefreshJob.stubs(:perform_later).raises(StandardError, "queue unavailable")

    assert_difference -> { DebugLogEntry.where(source: "SomeController", level: "error").count }, 1 do
      MarketDataRefreshJob.refresh_later(source: "SomeController")
    end
  end
end
