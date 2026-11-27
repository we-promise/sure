require "test_helper"

class SnaptradeActivitiesFetchJobTest < ActiveJob::TestCase
  setup do
    @snaptrade_account = snaptrade_accounts(:fidelity_401k)
    @snaptrade_account.update!(activities_fetch_pending: true)
    @provider = mock("snaptrade_provider")
    SnaptradeItem.any_instance.stubs(:snaptrade_provider).returns(@provider)
    SnaptradeItem.any_instance.stubs(:broadcast_sync_complete)
  end

  # Provider::Snaptrade returns an empty first page as it is, even when its
  # total is positive, so a connection SnapTrade is still importing is polled.
  test "an empty result is fetched again later" do
    @provider.expects(:get_account_activities).returns({ "data" => [], "pagination" => { "total" => 50 } })

    assert_enqueued_with(job: SnaptradeActivitiesFetchJob) do
      SnaptradeActivitiesFetchJob.perform_now(@snaptrade_account, start_date: 1.year.ago.to_date)
    end
    assert @snaptrade_account.reload.activities_fetch_pending?
  end

  # A raised fetch ends the job without another attempt, which is why the
  # provider must not raise on that empty first page.
  test "a fetch that raises is not retried and clears the pending flag" do
    @provider.expects(:get_account_activities).raises(Provider::Snaptrade::ApiError.new("incomplete"))

    assert_no_enqueued_jobs(only: SnaptradeActivitiesFetchJob) do
      SnaptradeActivitiesFetchJob.perform_now(@snaptrade_account, start_date: 1.year.ago.to_date)
    end
    assert_not @snaptrade_account.reload.activities_fetch_pending?
    assert_nil @snaptrade_account.last_activities_sync
  end
end
