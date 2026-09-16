require "test_helper"

class AutoSyncSchedulerTest < ActiveSupport::TestCase
  # Stubbed instead of hitting real Sidekiq::Cron (Redis): the JOB_NAME key
  # is global, so parallel test workers sharing the same Redis instance can
  # race and destroy each other's job mid-test (flaky NoMethodError on nil).
  setup do
    @job = OpenStruct.new(valid?: true)
  end

  test "sync! creates a cron job converted to UTC when enabled" do
    Setting.stubs(:auto_sync_enabled?).returns(true)
    Setting.stubs(:auto_sync_time).returns("02:22")
    Setting.stubs(:auto_sync_timezone).returns("UTC")

    Sidekiq::Cron::Job.expects(:create).with(
      name: AutoSyncScheduler::JOB_NAME,
      cron: "22 2 * * *",
      class: "SyncAllJob",
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
      has_entries(cron: "22 2 * * *")
    ).returns(@job)

    AutoSyncScheduler.upsert_job
  end
end
