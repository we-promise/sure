require "test_helper"

class WarmReportsCacheJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "warms every usual period for every member of the family" do
    @family.users.each do |user|
      ReportsController::WARMED_PERIOD_TYPES.each do |period_type|
        ReportsController.expects(:warm_body_cache).with(user: user, query: { period_type: period_type }).once
      end
    end

    WarmReportsCacheJob.perform_now(@family)
  end

  test "one view failing to build does not stop the rest" do
    attempts = @family.users.count * ReportsController::WARMED_PERIOD_TYPES.size
    ReportsController.expects(:warm_body_cache).times(attempts).raises(StandardError, "boom").then.returns(true)

    assert_nothing_raised { WarmReportsCacheJob.perform_now(@family) }
  end
end
