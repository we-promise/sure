require "test_helper"

class AutoSyncSchedulerTest < ActiveSupport::TestCase
  test "keeps the configured local sync time across daylight saving changes" do
    Setting.stubs(:auto_sync_time).returns("06:30")
    Setting.stubs(:auto_sync_timezone).returns("Europe/London")

    job = Object.new
    job.define_singleton_method(:valid?) { true }

    cron = "30 6 * * * Europe/London"
    Sidekiq::Cron::Job.expects(:create).with(
      name: AutoSyncScheduler::JOB_NAME,
      cron: cron,
      class: "SyncAllJob",
      queue: "scheduled",
      description: "Syncs all accounts for all families"
    ).returns(job)

    AutoSyncScheduler.upsert_job

    schedule = Fugit.parse_cron(cron)
    assert_equal "Europe/London", schedule.zone
    assert_equal Time.utc(2026, 1, 1, 6, 30), schedule.next_time(Time.utc(2026, 1, 1)).to_t.utc
    assert_equal Time.utc(2026, 7, 1, 5, 30), schedule.next_time(Time.utc(2026, 7, 1)).to_t.utc
  end
end
