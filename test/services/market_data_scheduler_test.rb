require "test_helper"

class MarketDataSchedulerTest < ActiveSupport::TestCase
  teardown do
    Sidekiq::Cron::Job.find(MarketDataScheduler::JOB_NAME)&.destroy
  end

  test "sync! creates a cron job with the correct UTC cron string when enabled" do
    Setting.stubs(:market_data_sync_enabled?).returns(true)
    Setting.stubs(:market_data_sync_time).returns("18:00")
    Setting.stubs(:market_data_sync_timezone).returns("UTC")

    MarketDataScheduler.sync!

    job = Sidekiq::Cron::Job.find(MarketDataScheduler::JOB_NAME)
    assert job, "Expected a cron job to be created"
    assert_equal "0 18 * * 1-5", job.cron
    assert_equal "ImportMarketDataJob", job.klass
  end

  test "sync! removes the cron job when disabled" do
    Setting.stubs(:market_data_sync_enabled?).returns(true)
    Setting.stubs(:market_data_sync_time).returns("18:00")
    Setting.stubs(:market_data_sync_timezone).returns("UTC")
    MarketDataScheduler.sync!
    assert Sidekiq::Cron::Job.find(MarketDataScheduler::JOB_NAME)

    Setting.stubs(:market_data_sync_enabled?).returns(false)
    MarketDataScheduler.sync!

    refute Sidekiq::Cron::Job.find(MarketDataScheduler::JOB_NAME)
  end

  test "upsert_job falls back to the default time on an invalid time format" do
    Setting.stubs(:market_data_sync_time).returns("not-a-time")
    Setting.stubs(:market_data_sync_timezone).returns("UTC")

    MarketDataScheduler.upsert_job

    job = Sidekiq::Cron::Job.find(MarketDataScheduler::JOB_NAME)
    assert_equal "0 22 * * 1-5", job.cron
  end
end
