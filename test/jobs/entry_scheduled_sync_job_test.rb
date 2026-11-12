require "test_helper"

class EntryScheduledSyncJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  test "schedule_for enqueues a job for the entry's account and date when scheduled" do
    entry = create_transaction(account: accounts(:depository), date: 3.days.from_now.to_date)

    assert_enqueued_with(job: EntryScheduledSyncJob, args: [ entry.account.id, entry.date ]) do
      EntryScheduledSyncJob.schedule_for(entry)
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

  test "schedule_for_entries judges future in the family's time zone" do
    family = families(:dylan_family)
    family.update!(timezone: "America/Los_Angeles")
    account = accounts(:depository)

    travel_to Time.zone.parse("2026-11-11 03:00 UTC") do
      # 2026-11-11 03:00 UTC is 2026-11-10 19:00 PT: still Nov 10 for the
      # family, so an entry dated Nov 11 is future-dated for it. The app's
      # Date.current (UTC) already reads Nov 11, which would skip it without
      # the family-zone judgment.
      entry = create_transaction(account: account, date: Date.new(2026, 11, 11))

      assert_enqueued_jobs 1, only: EntryScheduledSyncJob do
        EntryScheduledSyncJob.schedule_for_entries(Entry.where(id: entry.id))
      end
    end
  end

  test "perform triggers a sync for the entry's account" do
    entry = create_transaction(account: accounts(:depository), date: 3.days.from_now.to_date)

    Account.any_instance.expects(:sync_later).once

    EntryScheduledSyncJob.perform_now(entry.account.id, entry.date)
  end

  test "perform is a no-op when the account no longer exists" do
    assert_nothing_raised do
      EntryScheduledSyncJob.perform_now("nonexistent-id", Date.current)
    end
  end
end
