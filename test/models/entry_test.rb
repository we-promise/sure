require "test_helper"

class EntryTest < ActiveSupport::TestCase
  include EntriesTestHelper, ActiveJob::TestHelper

  test "chronological ordering uses id as final tie breaker" do
    account = accounts(:depository)
    timestamp = Time.zone.parse("2026-05-05 12:00:00")

    entries = 3.times.map do |index|
      create_transaction(
        account: account,
        name: "Same timestamp transaction #{index}",
        date: Date.new(2026, 5, 5),
        created_at: timestamp,
        updated_at: timestamp
      )
    end

    entry_ids = entries.map(&:id)

    assert_equal entry_ids.sort, Entry.where(id: entry_ids).chronological.pluck(:id)
    assert_equal entry_ids.sort.reverse, Entry.where(id: entry_ids).reverse_chronological.pluck(:id)
  end

  # Regression: lock_saved_attributes! and mark_user_modified! save again and used
  # to drop the original date, so moving an entry later double-counted it.
  test "sync_account_later keeps the original date across later saves" do
    entry = create_transaction(account: accounts(:depository), date: 5.days.ago.to_date)
    original_date = entry.date

    entry.update!(date: 2.days.ago.to_date)
    entry.update!(date: 1.day.ago.to_date)
    entry.lock_saved_attributes!
    entry.mark_user_modified!

    entry.account.expects(:sync_later).with(window_start_date: original_date)
    entry.sync_account_later
  end

  test "bulk_update! touches the assigned category's last_used_at" do
    entry = create_transaction(account: accounts(:depository))
    category = categories(:income)
    assert_nil category.last_used_at

    Entry.where(id: entry.id).bulk_update!({ category_id: category.id })

    assert_not_nil category.reload.last_used_at
  end

  test "bulk_update! syncs each account once and schedules the catch-up job when dates move into the future" do
    account = accounts(:depository)
    entries = [ create_transaction(account: account), create_transaction(account: account) ]
    new_date = 3.days.from_now.to_date

    Account.any_instance.expects(:sync_later).with(window_start_date: Date.current).once

    assert_enqueued_jobs 1, only: EntryScheduledSyncJob do
      Entry.where(id: entries.map(&:id)).bulk_update!({ date: new_date })
    end
  end

  test "bulk_update! neither syncs nor schedules when no date changes" do
    entry = create_transaction(account: accounts(:depository))

    Account.any_instance.expects(:sync_later).never

    assert_no_enqueued_jobs only: EntryScheduledSyncJob do
      Entry.where(id: entry.id).bulk_update!({ notes: "updated" })
    end
  end

  test "scheduled? is true only for entries dated after today" do
    travel_to Date.new(2026, 5, 5) do
      account = accounts(:depository)

      future_entry = create_transaction(account: account, date: 1.day.from_now.to_date)
      today_entry = create_transaction(account: account, date: Date.current)
      past_entry = create_transaction(account: account, date: 1.day.ago.to_date)

      assert future_entry.scheduled?
      assert_not today_entry.scheduled?
      assert_not past_entry.scheduled?
    end
  end
end
