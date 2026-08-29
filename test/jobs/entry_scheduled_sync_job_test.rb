require "test_helper"

class EntryScheduledSyncJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  test "schedule_for enqueues a job for the entry's date when scheduled" do
    entry = create_transaction(account: accounts(:depository), date: 3.days.from_now.to_date)

    assert_enqueued_with(job: EntryScheduledSyncJob, args: [ entry.id ]) do
      EntryScheduledSyncJob.schedule_for(entry)
    end
  end

  test "schedule_for does nothing for a non-scheduled entry" do
    entry = create_transaction(account: accounts(:depository), date: Date.current)

    assert_no_enqueued_jobs do
      EntryScheduledSyncJob.schedule_for(entry)
    end
  end

  test "perform triggers a sync for the entry's account" do
    entry = create_transaction(account: accounts(:depository), date: 3.days.from_now.to_date)

    Account.any_instance.expects(:sync_later).once

    EntryScheduledSyncJob.perform_now(entry.id)
  end

  test "perform is a no-op when the entry no longer exists" do
    assert_nothing_raised do
      EntryScheduledSyncJob.perform_now("nonexistent-id")
    end
  end
end
