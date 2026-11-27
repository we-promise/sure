require "test_helper"

class PlaidFollowUpSyncJobTest < ActiveJob::TestCase
  test "a job queued before follow-ups were built in still requests a sync" do
    plaid_item = plaid_items(:one)
    plaid_item.expects(:sync_later).once

    PlaidFollowUpSyncJob.perform_now(plaid_item, active_sync_id: SecureRandom.uuid, attempts_remaining: 30)
  end
end
