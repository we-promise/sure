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

  # Regression for the P2 setup-state bug (Codex review): finalize_setup_counts
  # must run AFTER perform_first_sync_auto_setup. The old order finalized the
  # setup counts (and the pending_account_setup flag) from the pre-auto-setup
  # UNLINKED count and never revisited it, so a first sync that auto-linked
  # everything still advertised "needs setup" (stale true). Now Phase 2
  # (auto-setup) runs before Phase 2.5 (finalize), so pending_account_setup
  # reflects the post-auto-setup linked state.
  test "first sync with auto-setup clears pending_account_setup instead of leaving it stale" do
    # One unlinked provider account exists on the item before the sync, so
    # has_completed_initial_setup? is false (auto-setup runs) and the finalize
    # counts move 1 unlinked → 0.
    @pluggy_item.pluggy_accounts.create!(
      pluggy_account_id: "pa-unlinked",
      name: "Checking", currency: "BRL", account_type: "BANK"
    )

    PluggyItem.any_instance.stubs(:import_latest_pluggy_data)
    # After auto-setup links the account, Phase 3/4 run process_accounts +
    # schedule_account_syncs, which hit the provider — stub so the test stays
    # offline. collect_transaction_stats is also stubbed for the same reason.
    PluggyItem.any_instance.stubs(:process_accounts)
    PluggyItem.any_instance.stubs(:schedule_account_syncs)
    PluggyItem::Syncer.any_instance.stubs(:collect_transaction_stats)

    sync = @pluggy_item.syncs.create!
    sync.perform

    @pluggy_item.reload
    # AutoSetup linked the provider account during the sync; the flag must now
    # reflect 0 unlinked — not the stale pre-auto-setup count of 1.
    assert_not @pluggy_item.pending_account_setup,
               "pending_account_setup should be false after auto-setup linked the account"
    # And the link actually happened (AutoSetup#create_account_for wired it).
    assert_equal 1, @pluggy_item.linked_accounts_count
  end

  # Regression for Codex P2 / #2861: Pluggy's docs state listing existing
  # connections "is not provided" (security policy —
  # https://docs.pluggy.ai/docs/item), so the Syncer MUST NOT discover a blank
  # pluggy_item_id from the provider API. The upstream id has to be persisted
  # from the widget / webhook / dashboard. With discovery removed (hydrate is
  # now a no-op), a blank id flows straight into import_latest_pluggy_data,
  # whose first call (Importer#get_item at importer.rb:18) needs that id to
  # build /items/:id and raises; the syncer's generic rescue surfaces it as
  # sync_error instead of silently minting "good". The
  # expects(:latest_item_id).never guard is the real lock — it fails if anyone
  # re-adds an eager hydrate that calls the listing endpoint (mirrors the #4
  # lock on create in pluggy_items_controller_test.rb).
  test "does not discover a blank pluggy_item_id from the provider API; a blank id surfaces a sync_error instead" do
    fresh = PluggyItem.create!(
      family: families(:dylan_family),
      name: "No-id Pluggy",
      client_id: "test_client",
      client_secret: "test_secret",
      status: :requires_update
    )

    # Discovery is gone — the listing helper must not be re-added.
    assert_not Provider::Pluggy.respond_to?(:latest_item_id)
    # A blank pluggy_item_id makes the importer's first get_item call fail
    # (needs the id to build /items/:id); stub the raise rather than hitting
    # the network, then let the syncer's generic rescue surface it.
    PluggyItem.any_instance.stubs(:import_latest_pluggy_data).raises(StandardError, "boom")

    sync = fresh.syncs.create!
    sync.perform

    fresh.reload
    sync.reload

    # The id stays blank — no fabricated discovery.
    assert_nil fresh.pluggy_item_id
    # The sync failed as a sync_error (not silently "good").
    assert_predicate sync, :failed?
    assert_equal "sync_error", sync.sync_stats.dig("errors", 0, "category")
    # And the item was NOT marked good.
    assert_not_equal "good", fresh.status
  end

  # Regression for PluggyItem#process_accounts swallowing processor-rescued
  # failures as success: true. PluggyAccount::Processor#process rescues
  # account-level failures and returns `{ error: }` instead of raising — a
  # blanket `success: true` on that result hid the failure from Syncer's
  # aggregation (which only counts `success: false`), so a partially failed sync
  # reported total_errors: 0 and marked the item good. The fix marks a returned
  # error hash success: false so collect_health_stats surfaces it.
  test "process_accounts marks a processor-returned error hash as success: false" do
    pa = @pluggy_item.pluggy_accounts.create!(
      pluggy_account_id: "pa-err", name: "Checking", currency: "BRL", account_type: "BANK"
    )

    # Stub the linked scope to include pa without the full AccountProvider
    # graph (process_accounts only needs the row to build the result hash and
    # call Processor — it doesn't read the linked Account here).
    linked_stub = Object.new
    linked_stub.stubs(:includes).returns([ pa ])
    @pluggy_item.stubs(:linked_pluggy_accounts).returns(linked_stub)

    # Processor#process returned a rescued error hash, not a raise.
    PluggyAccount::Processor.any_instance.stubs(:process).returns(error: "boom")

    results = @pluggy_item.process_accounts
    err = results.find { |r| r[:pluggy_account_id] == pa.id }
    assert_not err[:success],
               "processor-returned error hash must be success: false so Syncer aggregates it"
    assert_equal "boom", err[:error]
  end
end
