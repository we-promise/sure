require "test_helper"

class SyncHourlyJobTest < ActiveJob::TestCase
  test "syncs all active items for each hourly syncable class" do
    mock_item = mock("coinstats_item")
    mock_item.expects(:sync_later).once

    mock_relation = mock("active_relation")
    mock_relation.stubs(:find_each).yields(mock_item)

    CoinstatsItem.expects(:active).returns(mock_relation)
    SyncSchedule.stubs(:without_own_daily_schedule).with(mock_relation).returns(mock_relation)

    SyncHourlyJob.perform_now
  end

  test "continues syncing other items when one fails" do
    failing_item = mock("failing_item")
    failing_item.expects(:sync_later).raises(StandardError.new("Test error"))
    failing_item.stubs(:id).returns(1)

    success_item = mock("success_item")
    success_item.expects(:sync_later).once

    mock_relation = mock("active_relation")
    mock_relation.stubs(:find_each).multiple_yields([ failing_item ], [ success_item ])

    CoinstatsItem.expects(:active).returns(mock_relation)
    SyncSchedule.stubs(:without_own_daily_schedule).with(mock_relation).returns(mock_relation)

    assert_nothing_raised do
      SyncHourlyJob.perform_now
    end
  end

  test "leaves out items on their own schedule of a day or longer" do
    family = families(:dylan_family)
    hourly = family.coinstats_items.create!(name: "Hourly", api_key: "key-hourly")
    weekly = family.coinstats_items.create!(name: "Weekly", api_key: "key-weekly")
    weekly.create_sync_schedule!(interval_minutes: 10080)

    SyncHourlyJob.perform_now

    assert_equal 1, hourly.syncs.count
    assert_equal 0, weekly.syncs.count
  end
end
