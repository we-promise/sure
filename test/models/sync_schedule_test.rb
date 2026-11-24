require "test_helper"

class SyncScheduleTest < ActiveSupport::TestCase
  setup do
    @item = plaid_items(:one)
  end

  test "only the offered intervals are accepted" do
    schedule = @item.build_sync_schedule(interval_minutes: 45)

    assert_not schedule.valid?
    assert_includes schedule.errors[:interval_minutes], "is not included in the list"

    schedule.interval_minutes = 30
    assert schedule.valid?
  end

  test "a connection carries at most one schedule" do
    @item.create_sync_schedule!(interval_minutes: 60)
    duplicate = SyncSchedule.new(syncable: @item, interval_minutes: 30)

    assert_not duplicate.valid?
    assert duplicate.errors[:syncable_id].any?
  end

  test "only provider connections may be scheduled" do
    account = SyncSchedule.new(syncable: accounts(:depository), interval_minutes: 30)
    family = SyncSchedule.new(syncable: families(:dylan_family), interval_minutes: 30)

    assert_not account.valid?
    assert_not family.valid?
    assert SyncSchedule.new(syncable: wise_items(:one), interval_minutes: 30).valid?
  end

  test "schedulable associations are the family's syncable item associations" do
    associations = SyncSchedule.schedulable_associations

    assert_equal :plaid_items, associations["PlaidItem"]
    assert_equal :truelayer_items, associations["TruelayerItem"]
    assert_not associations.key?("Account")
  end

  # Runs land on multiples of the interval from midnight UTC, so a connection
  # on "every 6 hours" syncs at the same clock times every day.
  test "the next run is the first interval boundary after now" do
    travel_to Time.utc(2026, 11, 1, 10, 7, 30) do
      quarter_hourly = @item.create_sync_schedule!(interval_minutes: 15)
      assert_equal Time.utc(2026, 11, 1, 10, 15), quarter_hourly.next_run_at

      quarter_hourly.update!(interval_minutes: 360)
      assert_equal Time.utc(2026, 11, 1, 12, 0), quarter_hourly.next_run_at
    end
  end

  test "advancing moves to the boundary after the given time, never the same one" do
    schedule = @item.create_sync_schedule!(interval_minutes: 30)
    schedule.update_column(:next_run_at, Time.utc(2026, 11, 1, 10, 30))

    assert schedule.advance!(from: Time.utc(2026, 11, 1, 10, 30, 0, 400_000))
    assert_equal Time.utc(2026, 11, 1, 11, 0), schedule.next_run_at

    assert schedule.advance!(from: Time.utc(2026, 11, 1, 11, 0))
    assert_equal Time.utc(2026, 11, 1, 11, 30), schedule.next_run_at
  end

  test "advancing counts in the interval saved since the row was loaded" do
    schedule = @item.create_sync_schedule!(interval_minutes: 15)
    SyncSchedule.where(id: schedule.id).update_all(interval_minutes: 720, next_run_at: Time.utc(2026, 11, 1, 10, 0))

    assert schedule.advance!(from: Time.utc(2026, 11, 1, 10, 5))

    assert_equal Time.utc(2026, 11, 1, 12, 0), schedule.next_run_at
  end

  # The job loads every due row before advancing any of them; a schedule
  # changed in between was realigned to the future and is not run.
  test "advancing a schedule that is no longer due leaves it and reports false" do
    travel_to Time.utc(2026, 11, 1, 10, 7) do
      loaded = @item.create_sync_schedule!(interval_minutes: 15)
      loaded.update_column(:next_run_at, Time.utc(2026, 11, 1, 10, 0))
      SyncSchedule.find(loaded.id).update!(interval_minutes: 60)

      assert_not loaded.advance!
      assert_equal Time.utc(2026, 11, 1, 11, 0), loaded.next_run_at
      assert_equal 60, loaded.interval_minutes
    end
  end

  test "advancing a schedule removed since it was loaded reports false" do
    loaded = @item.create_sync_schedule!(interval_minutes: 15)
    SyncSchedule.where(id: loaded.id).delete_all

    assert_not loaded.advance!
  end

  test "assign creates the schedule on first use and changes it after" do
    schedule = SyncSchedule.assign(@item, 60)
    assert schedule.persisted?
    assert_equal 60, @item.reload.sync_schedule.interval_minutes

    SyncSchedule.assign(@item, 30)
    assert_equal 30, @item.reload.sync_schedule.interval_minutes
    assert_equal 1, SyncSchedule.where(syncable: @item).count
  end

  test "assign reports a rejected interval without saving" do
    schedule = SyncSchedule.assign(@item, 45)

    assert schedule.errors[:interval_minutes].any?
    assert_nil @item.reload.sync_schedule
  end

  # Two requests for a connection with no schedule both find none and both
  # pass the uniqueness validation; the unique index turns the second away.
  test "assign applies the interval to a schedule created by a concurrent request" do
    assert_nil @item.sync_schedule
    competing = SyncSchedule.create!(syncable_type: "PlaidItem", syncable_id: @item.id, interval_minutes: 60)
    ActiveRecord::Validations::UniquenessValidator.any_instance.stubs(:validate_each)

    schedule = SyncSchedule.assign(@item, 30)

    assert_equal competing.id, schedule.id
    assert_equal 30, competing.reload.interval_minutes
    assert_equal 1, SyncSchedule.where(syncable: @item).count
  end

  test "admins may edit any connection's schedule, members only one they own on an ownable provider" do
    admin = users(:family_admin)
    member = users(:family_member)
    redbark = redbark_items(:one)

    assert SyncSchedule.editable_by?(@item, admin)
    assert SyncSchedule.editable_by?(redbark, admin)
    assert_not SyncSchedule.editable_by?(@item, member)
    assert_not SyncSchedule.editable_by?(redbark, member)
    assert_not SyncSchedule.editable_by?(@item, nil)

    @item.update!(owner: member)
    assert SyncSchedule.editable_by?(@item, member)
  end

  test "a connection being deleted takes no schedule" do
    @item.update_column(:scheduled_for_deletion, true)

    assert_not SyncSchedule.editable_by?(@item, users(:family_admin))
  end

  test "due lists schedules whose time has come" do
    due = @item.create_sync_schedule!(interval_minutes: 15)
    due.update_column(:next_run_at, 1.minute.ago)
    later = wise_items(:one).create_sync_schedule!(interval_minutes: 15)

    assert_includes SyncSchedule.due, due
    assert_not_includes SyncSchedule.due, later
  end
end
