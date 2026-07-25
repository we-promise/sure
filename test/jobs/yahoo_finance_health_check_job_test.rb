require "test_helper"

class YahooFinanceHealthCheckJobTest < ActiveJob::TestCase
  test "refreshes Yahoo Finance health status" do
    provider = mock
    provider.expects(:refresh_health_status).once
    Provider::YahooFinance.expects(:new).returns(provider)

    YahooFinanceHealthCheckJob.perform_now
  end
end
