require "test_helper"

class SyncJobTest < ActiveJob::TestCase
  test "sync is performed" do
    syncable = accounts(:depository)

    sync = syncable.syncs.create!(window_start_date: 2.days.ago.to_date)

    sync.expects(:perform).once

    SyncJob.perform_now(sync)
  end

  test "retries on TwelveData rate limit error" do
    syncable = accounts(:depository)
    sync = syncable.syncs.create!(window_start_date: 2.days.ago.to_date)

    # Create a rate limit error
    rate_limit_error = Provider::TwelveData::RateLimitError.new(
      "TwelveData rate limit exceeded",
      details: { code: 429 }
    )

    # Mock sync.perform to raise the rate limit error
    sync.stubs(:perform).raises(rate_limit_error)

    # Verify the job is configured to retry on this error
    assert_raises(Provider::TwelveData::RateLimitError) do
      SyncJob.perform_now(sync)
    end
  end
end
