require "test_helper"

class RebuildReportJobTest < ActiveJob::TestCase
  test "rebuilds the member's report for the query their page carried" do
    user = users(:family_admin)
    ReportsController.expects(:warm_body_cache).with(user: user, query: { period_type: "ytd" }, locale: "de").once

    RebuildReportJob.perform_now(user, { period_type: "ytd" }, "de")
  end

  test "a rebuild queued before the locale was passed along still runs" do
    user = users(:family_admin)
    ReportsController.expects(:warm_body_cache).with(user: user, query: { period_type: "ytd" }, locale: nil).once

    RebuildReportJob.perform_now(user, { period_type: "ytd" })
  end
end
