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

  test "does not overlap an incomplete sync hidden from the UI" do
    plaid_item = plaid_items(:one)
    plaid_item.syncs.destroy_all
    active_sync = plaid_item.syncs.create!(created_at: Sync::VISIBLE_FOR.ago - 1.minute)
    active_sync.start!

    assert_enqueued_with job: PlaidFollowUpSyncJob do
      PlaidFollowUpSyncJob.perform_now(plaid_item, active_sync_id: active_sync.id, attempts_remaining: 1)
    end
  end

  test "captures exhausted retries for support" do
    plaid_item = plaid_items(:one)
    plaid_item.syncs.destroy_all
    active_sync = plaid_item.syncs.create!
    active_sync.start!

    assert_difference "DebugLogEntry.count", 1 do
      PlaidFollowUpSyncJob.perform_now(plaid_item, active_sync_id: active_sync.id, attempts_remaining: 0)
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "background_jobs", entry.category
    assert_equal "PlaidFollowUpSyncJob", entry.source
    assert_equal plaid_item.family, entry.family
    assert_equal active_sync.id, entry.metadata["active_sync_id"]
  end
end
