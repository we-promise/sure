require "test_helper"

# Tests PluggyItem::Syncer#perform_sync (the entry called by Syncable#perform_sync,
# which Sync#perform invokes). Mirrors the AkahuItem::SyncerTest pattern: drive a
# real Sync record through `sync.perform`, stub the model's import method, and assert
# the syncer's status transitions + health-stats capture.
class PluggyItem::SyncerTest < ActiveSupport::TestCase
  setup do
    # Fresh item so collect_setup_stats has no provider accounts to iterate, and so
    # the success status transition is observable (start non-good).
    @pluggy_item = PluggyItem.create!(
      family: families(:dylan_family),
      name: "Test Pluggy",
      client_id: "test_client",
      client_secret: "test_secret",
      pluggy_item_id: "item-test",
      status: :requires_update
    )

    # Sync#perform's finalization calls syncable.perform_post_sync + syncable.broadcast_sync_complete.
    # Broadcast wiring (SyncCompleteEvent) is covered elsewhere; stub to keep the test isolated.
    PluggyItem.any_instance.stubs(:perform_post_sync)
    PluggyItem.any_instance.stubs(:broadcast_sync_complete)
  end

  test "successful sync marks item good and completes the sync" do
    PluggyItem.any_instance.stubs(:import_latest_pluggy_data)

    sync = @pluggy_item.syncs.create!
    sync.perform

    @pluggy_item.reload
    sync.reload

    assert_equal "good", @pluggy_item.status
    assert_not_predicate sync, :failed?
    assert_equal 0, sync.sync_stats["total_errors"]
  end

  test "authentication error marks item requires_update and fails the sync with auth_error category" do
    PluggyItem.any_instance.stubs(:import_latest_pluggy_data).raises(
      Provider::Pluggy::AuthenticationError.new("Invalid credentials", :unauthorized)
    )

    sync = @pluggy_item.syncs.create!
    sync.perform

    @pluggy_item.reload
    sync.reload

    assert_predicate sync, :failed?
    assert_equal "requires_update", @pluggy_item.status
    assert_equal 1, sync.sync_stats["total_errors"]
    assert_equal "auth_error", sync.sync_stats.dig("errors", 0, "category")
  end

  test "unexpected error re-raises as sync_error and fails the sync" do
    PluggyItem.any_instance.stubs(:import_latest_pluggy_data).raises(StandardError, "boom")

    sync = @pluggy_item.syncs.create!
    sync.perform

    @pluggy_item.reload
    sync.reload

    assert_predicate sync, :failed?
    assert_equal "sync_error", sync.sync_stats.dig("errors", 0, "category")
  end

  test "orchestrates process_accounts and schedule_account_syncs for linked accounts" do
    PluggyItem.any_instance.stubs(:import_latest_pluggy_data)
    PluggyItem::Syncer.any_instance.stubs(:collect_transaction_stats)

    # linked_pluggy_accounts returns an AR relation in production; stub it to a
    # linked-collection mock so the process-accounts phase is entered without
    # needing a PluggyAccount::Processor (T16).
    linked_stub = Object.new
    linked_stub.stubs(:includes).returns(linked_stub)
    linked_stub.stubs(:any?).returns(true)
    linked_stub.stubs(:filter_map).returns([])
    PluggyItem.any_instance.stubs(:linked_pluggy_accounts).returns(linked_stub)

    PluggyItem.any_instance.expects(:process_accounts).once
    PluggyItem.any_instance.expects(:schedule_account_syncs).once

    sync = @pluggy_item.syncs.create!
    sync.perform

    @pluggy_item.reload
    assert_equal "good", @pluggy_item.status
  end
end
