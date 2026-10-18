require "test_helper"
require Rails.root.join("lib/daily_job_usage_tracking")

class DailyJobUsageTrackingTest < ActiveSupport::TestCase
  test "server execution captures without forwarding job metadata and preserves return value" do
    DailyInstallationUsage.expects(:capture).with("job_served_daily").once
    result = DailyJobUsageTracking.new.call(Object.new, { "class" => "PrivateJob", "args" => [ "private" ] }, "private_queue") { :done }
    assert_equal :done, result
  end

  test "failed execution and retries reach the daily claim and retain the job error" do
    DailyInstallationUsage.expects(:capture).with("job_served_daily").twice
    2.times do
      assert_raises(ArgumentError) do
        DailyJobUsageTracking.new.call(nil, {}, nil) { raise ArgumentError, "job failed" }
      end
    end
  end
end
