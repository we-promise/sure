require "test_helper"

class EntryTest < ActiveSupport::TestCase
  include EntriesTestHelper

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

  test "chronological ordering sorts same-day entries by time when present" do
    account = accounts(:depository)
    date = Date.new(2026, 5, 5)

    # Created out of time order, so the assertions below only pass if
    # entries are actually sorted by time and not by creation order.
    evening = create_transaction(account: account, name: "Evening", date: date, time: "20:00")
    morning = create_transaction(account: account, name: "Morning", date: date, time: "09:00")
    afternoon = create_transaction(account: account, name: "Afternoon", date: date, time: "14:30")

    entry_ids = [ morning.id, afternoon.id, evening.id ]

    assert_equal [ morning.id, afternoon.id, evening.id ],
      Entry.where(id: entry_ids).chronological.pluck(:id)
    assert_equal [ evening.id, afternoon.id, morning.id ],
      Entry.where(id: entry_ids).reverse_chronological.pluck(:id)
  end

  test "chronological ordering sorts entries without a time after entries with a time, in both directions" do
    account = accounts(:depository)
    date = Date.new(2026, 5, 5)

    # Created out of order for the same reason as above: creation order
    # must not coincidentally match the expected time-sorted order.
    untimed = create_transaction(account: account, name: "Untimed", date: date, time: nil)
    timed = create_transaction(account: account, name: "Timed", date: date, time: "09:00")

    entry_ids = [ timed.id, untimed.id ]

    assert_equal [ timed.id, untimed.id ],
      Entry.where(id: entry_ids).chronological.pluck(:id)
    assert_equal [ timed.id, untimed.id ],
      Entry.where(id: entry_ids).reverse_chronological.pluck(:id)
  end

  test "time is stored and read as a naive wall-clock value, independent of Time.zone" do
    account = accounts(:depository)
    entry = nil

    Time.use_zone("America/New_York") do
      entry = create_transaction(account: account, date: Date.current, time: "14:30")
    end

    raw_value = ActiveRecord::Base.connection.select_value(
      "SELECT time FROM entries WHERE id = #{ActiveRecord::Base.connection.quote(entry.id)}"
    )
    assert_equal "14:30:00", raw_value

    Time.use_zone("Asia/Tokyo") do
      assert_equal "14:30", entry.reload.time.strftime("%H:%M")
    end
  end

  test "an unparseable time is a validation error, not a silent nil" do
    entry = create_transaction(account: accounts(:depository), time: nil)
    entry.time = "not-a-time"

    assert_not entry.valid?
    assert_includes entry.errors[:time], "is not a valid time"
  end

  test "blank time is allowed and clears an existing time" do
    entry = create_transaction(account: accounts(:depository), time: "09:00")

    entry.update!(time: "")

    assert_nil entry.reload.time
  end

  test "an unparseable time update is rejected and does not clear the existing time" do
    entry = create_transaction(account: accounts(:depository), time: "09:00")

    assert_not entry.update(time: "not-a-time")
    assert_equal "09:00", entry.reload.time.strftime("%H:%M")
  end

  test "a time with a UTC offset is rejected instead of being normalized to a different value" do
    entry = create_transaction(account: accounts(:depository), time: nil)
    entry.time = "14:30:00+03:00"

    assert_not entry.valid?
    assert_includes entry.errors[:time], "is not a valid time"
  end

  test "a time with seconds is rejected instead of silently sorting on hidden precision" do
    entry = create_transaction(account: accounts(:depository), time: nil)
    entry.time = "14:30:45"

    assert_not entry.valid?
    assert_includes entry.errors[:time], "is not a valid time"
  end

  test "an assigned Time value with nonzero seconds is rejected, not just raw strings" do
    entry = create_transaction(account: accounts(:depository), time: nil)
    entry.time = Time.current

    assert_not entry.valid?
    assert_includes entry.errors[:time], "is not a valid time"
  end

  test "a non-time value assigned to time is rejected, not raised" do
    entry = create_transaction(account: accounts(:depository), time: nil)
    entry.time = 123

    assert_not entry.valid?
    assert_includes entry.errors[:time], "is not a valid time"
  end

  test "a minute-precision Time with a non-UTC offset is rejected instead of shifting hours" do
    entry = create_transaction(account: accounts(:depository), time: nil)
    entry.time = Time.new(2024, 1, 1, 14, 30, 0, "-04:00")

    assert_not entry.valid?
    assert_includes entry.errors[:time], "is not a valid time"
  end

  test "reloading an existing time does not re-trigger the format check" do
    entry = create_transaction(account: accounts(:depository), time: "14:30")

    reloaded = Entry.find(entry.id)

    assert reloaded.valid?
    assert reloaded.update(name: "Renamed")
  end

  test "bulk_update! touches the assigned category's last_used_at" do
    entry = create_transaction(account: accounts(:depository))
    category = categories(:income)
    assert_nil category.last_used_at

    Entry.where(id: entry.id).bulk_update!({ category_id: category.id })

    assert_not_nil category.reload.last_used_at
  end
end
