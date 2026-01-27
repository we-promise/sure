require "test_helper"

class SyncJobTest < ActiveJob::TestCase
  test "sync is performed" do
    syncable = accounts(:depository)

    sync = syncable.syncs.create!(window_start_date: 2.days.ago.to_date)

    sync.expects(:perform).once

    SyncJob.perform_now(sync)
  end

  test "configured to retry on TwelveData rate limit error" do
    # Verify that SyncJob has a rescue handler for Provider::TwelveData::RateLimitError
    # The retry_on declaration adds a rescue_from handler
    handler_found = SyncJob.rescue_handlers.any? do |handler|
      handler.is_a?(Hash) &&
      handler[:exception] == Provider::TwelveData::RateLimitError
    end

    assert handler_found, "SyncJob should have retry_on configured for Provider::TwelveData::RateLimitError"
  end
end
