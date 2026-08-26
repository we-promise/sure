require "test_helper"

class PlaidFollowUpSyncJobTest < ActiveJob::TestCase
  test "starts a sync after the active sync finishes" do
    plaid_item = plaid_items(:one)
    plaid_item.syncs.destroy_all
    plaid_item.expects(:sync_later).once

    PlaidFollowUpSyncJob.perform_now(plaid_item, active_sync_id: SecureRandom.uuid)
  end

  test "reschedules while a sync is active" do
    plaid_item = plaid_items(:one)
    plaid_item.syncs.destroy_all
    active_sync = plaid_item.syncs.create!
    active_sync.start!

    assert_enqueued_with job: PlaidFollowUpSyncJob do
      PlaidFollowUpSyncJob.perform_now(plaid_item, active_sync_id: active_sync.id, attempts_remaining: 1)
    end
  end
end
