require "test_helper"

class EntryScheduledSyncJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  test "schedule_for enqueues a job for the entry's date when scheduled" do
    entry = create_transaction(account: accounts(:depository), date: 3.days.from_now.to_date)

    assert_enqueued_with(job: EntryScheduledSyncJob, args: [ entry.id, entry.account_id ]) do
      EntryScheduledSyncJob.schedule_for(entry)
    end
  end

  test "schedule_for enqueues when the entry is dated tomorrow in the family's time zone" do
    families(:dylan_family).update!(timezone: "America/Los_Angeles")

    # 04:00 UTC is 20:00 the previous day in Los Angeles: the app already
    # calls it tomorrow, the family still calls it today.
    travel_to Time.utc(2026, 11, 11, 4, 0, 0) do
      entry = create_transaction(account: accounts(:depository), date: Date.new(2026, 11, 11))
      expected_run_at = entry.date.in_time_zone("America/Los_Angeles") + 5.minutes

      assert_enqueued_with(job: EntryScheduledSyncJob, args: [ entry.id, entry.account_id ], at: expected_run_at) do
        EntryScheduledSyncJob.schedule_for(entry)
      end
    end
  end

  test "schedule_for runs just after midnight in the family's timezone" do
    families(:dylan_family).update!(timezone: "America/New_York")
    entry = create_transaction(account: accounts(:depository), date: 3.days.from_now.to_date)
    expected_run_at = entry.date.in_time_zone("America/New_York") + 5.minutes

    assert_enqueued_with(job: EntryScheduledSyncJob, at: expected_run_at) do
      EntryScheduledSyncJob.schedule_for(entry)
    end
  end

  test "schedule_for does nothing for a non-scheduled entry" do
    entry = create_transaction(account: accounts(:depository), date: Date.current)

    assert_no_enqueued_jobs do
      EntryScheduledSyncJob.schedule_for(entry)
    end
  end

  test "schedule_for_entries enqueues one job per account and date, skipping non-scheduled entries" do
    account = accounts(:depository)
    date = 3.days.from_now.to_date
    first = create_transaction(account: account, date: date)
    second = create_transaction(account: account, date: date)
    later = create_transaction(account: account, date: date + 1.day)
    today = create_transaction(account: account, date: Date.current)

    assert_enqueued_jobs 2, only: EntryScheduledSyncJob do
      EntryScheduledSyncJob.schedule_for_entries(Entry.where(id: [ first.id, second.id, later.id, today.id ]))
    end
  end

  test "schedule_for_entries includes entries dated tomorrow in the family's time zone" do
    families(:dylan_family).update!(timezone: "America/Los_Angeles")

    travel_to Time.utc(2026, 11, 11, 4, 0, 0) do
      entry = create_transaction(account: accounts(:depository), date: Date.new(2026, 11, 11))

      assert_enqueued_jobs 1, only: EntryScheduledSyncJob do
        EntryScheduledSyncJob.schedule_for_entries(Entry.where(id: entry.id))
      end
    end
  end

  test "perform still syncs the account when the representative entry was deleted" do
    entry = create_transaction(account: accounts(:depository), date: 3.days.from_now.to_date)
    account = entry.account
    entry.destroy!

    Account.any_instance.expects(:sync_later).once

    EntryScheduledSyncJob.perform_now(entry.id, account.id)
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
