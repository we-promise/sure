require "test_helper"
require "ostruct"

class AutoSyncSchedulerTest < ActiveSupport::TestCase
  # Stubbed instead of hitting real Sidekiq::Cron (Redis): the JOB_NAME key
  # is global, so parallel test workers sharing the same Redis instance can
  # race and destroy each other's job mid-test (flaky NoMethodError on nil).
  setup do
    @job = OpenStruct.new(valid?: true)
  end

  test "sync! creates a cron job in the configured timezone when enabled" do
    Setting.stubs(:auto_sync_enabled?).returns(true)
    Setting.stubs(:auto_sync_time).returns("02:22")
    Setting.stubs(:auto_sync_timezone).returns("UTC")

    Sidekiq::Cron::Job.expects(:create).with(
      name: AutoSyncScheduler::JOB_NAME,
      cron: "22 2 * * * Etc/UTC",
      class: "SyncAllJob",
      active_job: true,
      queue: "scheduled",
      description: "Syncs all accounts for all families"
    ).returns(@job)

    AutoSyncScheduler.sync!
  end

  test "sync! removes the cron job when disabled" do
    Setting.stubs(:auto_sync_enabled?).returns(false)
    Setting.stubs(:auto_sync_time).returns("02:22")
    Sidekiq::Cron::Job.expects(:find).with(AutoSyncScheduler::JOB_NAME).returns(@job)
    @job.expects(:destroy)

    AutoSyncScheduler.sync!
  end

  test "upsert_job falls back to the default time on an invalid time format" do
    Setting.stubs(:auto_sync_time).returns("not-a-time")
    Setting.stubs(:auto_sync_timezone).returns("UTC")

    Sidekiq::Cron::Job.expects(:create).with(
      has_entries(cron: "22 2 * * * Etc/UTC")
    ).returns(@job)

    AutoSyncScheduler.upsert_job
  end

  test "keeps the configured local sync time across daylight saving changes" do
    Setting.stubs(:auto_sync_time).returns("06:30")
    Setting.stubs(:auto_sync_timezone).returns("Europe/London")

    job = OpenStruct.new(valid?: true)

    cron = "30 6 * * * Europe/London"
    Sidekiq::Cron::Job.expects(:create).with(
      name: AutoSyncScheduler::JOB_NAME,
      cron: cron,
      class: "SyncAllJob",
      active_job: true,
      queue: "scheduled",
      description: "Syncs all accounts for all families"
    ).returns(job)

    AutoSyncScheduler.upsert_job

    schedule = Fugit.parse_cron(cron)
    assert_equal "Europe/London", schedule.zone
    assert_equal Time.utc(2026, 1, 1, 6, 30), schedule.next_time(Time.utc(2026, 1, 1)).to_t.utc
    assert_equal Time.utc(2026, 7, 1, 5, 30), schedule.next_time(Time.utc(2026, 7, 1)).to_t.utc
  end

  # https://github.com/we-promise/sure/issues/1442
  test "registers the sync_all_accounts cron job as an ActiveJob" do
    Sidekiq::Cron::Job.expects(:create)
      .with(has_entries(name: AutoSyncScheduler::JOB_NAME, class: "SyncAllJob", active_job: true))
      .returns(stub(valid?: true))

    AutoSyncScheduler.upsert_job
  end
end
