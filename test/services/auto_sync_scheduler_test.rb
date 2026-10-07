require "test_helper"

class AutoSyncSchedulerTest < ActiveSupport::TestCase
  # https://github.com/we-promise/sure/issues/1442
  test "registers the sync_all_accounts cron job as an ActiveJob" do
    Sidekiq::Cron::Job.expects(:create)
      .with(has_entries(name: AutoSyncScheduler::JOB_NAME, class: "SyncAllJob", active_job: true))
      .returns(stub(valid?: true))

    AutoSyncScheduler.upsert_job
  end
end
