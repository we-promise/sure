require "test_helper"

class MarketDataSchedulerTest < ActiveSupport::TestCase
  # Stubbed instead of hitting real Sidekiq::Cron (Redis): the JOB_NAME key
  # is global, so parallel test workers sharing the same Redis instance can
  # race and destroy each other's job mid-test (flaky NoMethodError on nil).
  setup do
    @job = OpenStruct.new(valid?: true)
  end

  test "sync! creates a cron job with the correct UTC cron string when enabled" do
    Setting.stubs(:market_data_sync_enabled?).returns(true)
    Setting.stubs(:market_data_sync_time).returns("18:00")
    Setting.stubs(:market_data_sync_timezone).returns("UTC")

    Sidekiq::Cron::Job.expects(:create).with(
      name: MarketDataScheduler::JOB_NAME,
      cron: "0 18 * * 1-5 Etc/UTC",
      class: "ImportMarketDataJob",
      queue: "scheduled",
      args: { mode: "full", clear_cache: false },
      description: "Imports market data daily (Mon-Fri) at the configured time"
    ).returns(@job)

    MarketDataScheduler.sync!
  end

  test "upsert_job embeds the configured IANA timezone instead of converting to UTC" do
    Setting.stubs(:market_data_sync_time).returns("22:00")
    Setting.stubs(:market_data_sync_timezone).returns("Pacific Time (US & Canada)")

    # The local hour/weekday are preserved verbatim (no UTC conversion), so
    # the job always fires at 22:00 local time regardless of daylight-saving
    # transitions or how far the local date is from the UTC date boundary.
    Sidekiq::Cron::Job.expects(:create).with(
      has_entries(cron: "0 22 * * 1-5 America/Los_Angeles")
    ).returns(@job)

    MarketDataScheduler.upsert_job
  end

  test "sync! removes the cron job when disabled" do
    Setting.stubs(:market_data_sync_enabled?).returns(false)
    Sidekiq::Cron::Job.expects(:find).with(MarketDataScheduler::JOB_NAME).returns(@job)
    @job.expects(:destroy)

    MarketDataScheduler.sync!
  end

  test "upsert_job falls back to the default time on an invalid time format" do
    Setting.stubs(:market_data_sync_time).returns("not-a-time")
    Setting.stubs(:market_data_sync_timezone).returns("UTC")

    Sidekiq::Cron::Job.expects(:create).with(
      has_entries(cron: "0 22 * * 1-5 Etc/UTC")
    ).returns(@job)

    MarketDataScheduler.upsert_job
  end
end
