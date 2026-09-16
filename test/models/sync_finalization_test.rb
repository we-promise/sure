require "test_helper"
require_relative "../support/provider_ingestion_test_helper"

class SyncFinalizationTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  setup do
    Sentry.stubs(:capture_exception)
    # This suite isolates finalization state/rollback inside fixture transactions.
    # SyncOwnerAdmissionTest covers actual outer-commit parent propagation.
    ActiveRecord.stubs(:after_all_transactions_commit).yields
  end

  test "fresh finalizers run completed sync post work only once" do
    sync = Sync.create!(syncable: accounts(:depository), status: "completed")
    Account.any_instance.expects(:perform_post_sync).once
    Account.any_instance.expects(:broadcast_sync_complete).once

    sync.finalize_if_all_children_finalized
    completed_at = sync.reload.post_sync_completed_at
    assert completed_at
    Sync.find(sync.id).finalize_if_all_children_finalized

    assert_equal completed_at, sync.reload.post_sync_completed_at
    assert sync.completed?
  end

  test "successful finalization commits the status and post marker together" do
    sync = Sync.create!(syncable: accounts(:depository), status: "syncing")
    Account.any_instance.expects(:perform_post_sync).once
    Account.any_instance.expects(:broadcast_sync_complete).once

    sync.finalize_if_all_children_finalized

    assert sync.reload.completed?
    assert sync.completed_at
    assert sync.post_sync_completed_at
  end

  test "a failed parent waits for delayed children then runs post work once without changing its failure" do
    parent = Sync.create!(syncable: families(:dylan_family), status: "failed", error: "Original provider failure")
    child = Sync.create!(syncable: accounts(:depository), parent: parent, status: "syncing")
    Family.any_instance.expects(:perform_post_sync).once
    Family.any_instance.expects(:broadcast_sync_complete).once
    Account.any_instance.expects(:perform_post_sync).once
    Account.any_instance.expects(:broadcast_sync_complete).once

    parent.finalize_if_all_children_finalized
    assert_nil parent.reload.post_sync_completed_at
    child.finalize_if_all_children_finalized
    marker = parent.reload.post_sync_completed_at
    assert marker
    Sync.find(child.id).finalize_if_all_children_finalized

    assert child.reload.completed?
    assert parent.reload.failed?
    assert_equal "Original provider failure", parent.error
    assert_equal marker, parent.post_sync_completed_at
  end

  test "a previously marked child still propagates finalization to its newly ready parent" do
    parent = Sync.create!(syncable: families(:dylan_family), status: "pending")
    marker = 1.minute.ago.change(usec: 0)
    child = Sync.create!(syncable: accounts(:depository), parent: parent, status: "completed", post_sync_completed_at: marker)
    Account.any_instance.expects(:perform_post_sync).never
    Account.any_instance.expects(:broadcast_sync_complete).never
    Family.any_instance.expects(:perform_post_sync).once
    Family.any_instance.expects(:broadcast_sync_complete).once

    child.finalize_if_all_children_finalized
    assert_nil parent.reload.post_sync_completed_at
    parent.update!(status: "syncing")
    Sync.find(child.id).finalize_if_all_children_finalized

    assert parent.reload.completed?
    assert parent.post_sync_completed_at
    assert_equal marker, child.reload.post_sync_completed_at
  end

  test "pending executions and providers still doing their own work do not finalize early" do
    with_provider_encryption do
      pending = Sync.create!(syncable: accounts(:depository))
      provider = create_provider_connection
      running = provider.syncs.create!(status: "syncing")
      Account.any_instance.expects(:perform_post_sync).never
      ProviderConnection.any_instance.expects(:perform_post_sync).once
      ProviderConnection.any_instance.expects(:broadcast_sync_complete).once

      pending.finalize_if_all_children_finalized
      running.finalize_if_all_children_finalized
      assert pending.reload.pending?
      assert_nil pending.post_sync_completed_at
      assert running.reload.syncing?
      assert_nil running.post_sync_completed_at

      finished_at = Time.current.change(usec: 0)
      running.update!(provider_work_finished_at: finished_at)
      running.finalize_if_all_children_finalized
      assert running.reload.completed?
      assert_equal finished_at, running.provider_work_finished_at
      assert running.post_sync_completed_at
    end
  end

  test "stale and cancelled executions skip post effects and still resolve their parent" do
    parent = Sync.create!(syncable: families(:dylan_family), status: "syncing")
    stale = Sync.create!(syncable: accounts(:depository), parent: parent, status: "stale")
    cancelled = Sync.create!(syncable: accounts(:investment), parent: parent, status: "syncing", cancel_requested_at: Time.current)
    Account.any_instance.expects(:perform_post_sync).never
    Account.any_instance.expects(:broadcast_sync_complete).never
    Family.any_instance.expects(:perform_post_sync).once
    Family.any_instance.expects(:broadcast_sync_complete).once

    stale.finalize_if_all_children_finalized
    assert parent.reload.syncing?
    cancelled.finalize_if_all_children_finalized
    Sync.find(stale.id).finalize_if_all_children_finalized

    assert stale.reload.stale?
    assert cancelled.reload.stale?
    assert_nil stale.post_sync_completed_at
    assert_nil cancelled.post_sync_completed_at
    assert parent.reload.completed?
    assert parent.post_sync_completed_at
  end

  test "failed post work rolls back database effects and status and can be retried" do
    owner = accounts(:depository)
    original_name = owner.name
    sync = Sync.create!(syncable: owner, status: "syncing")
    failing = lambda do
      Account.where(id: owner.id).update_all(name: "Uncommitted post effect")
      raise IOError, "Interrupted post work"
    end
    successful = -> { Account.where(id: owner.id).update_all(name: "Committed post effect") }
    owner.expects(:broadcast_sync_complete).once

    sync.stub(:syncable, owner) do
      owner.stub(:perform_post_sync, failing) do
        assert_raises(IOError) { sync.finalize_if_all_children_finalized }
      end
      assert sync.reload.syncing?
      assert_nil sync.completed_at
      assert_nil sync.post_sync_completed_at
      assert_equal original_name, owner.reload.name

      owner.stub(:perform_post_sync, successful) { sync.finalize_if_all_children_finalized }
    end

    assert sync.reload.completed?
    assert sync.post_sync_completed_at
    assert_equal "Committed post effect", owner.reload.name
  end

  test "rescued post failure inside an outer transaction preserves previously committed status and work markers" do
    with_provider_encryption do
      owner = create_provider_connection
      finished_at = Time.current.change(usec: 0)
      sync = owner.syncs.create!(status: "failed", error: "Original failure", provider_work_finished_at: finished_at)
      original_name = owner.name
      failing = lambda do
        ProviderConnection.where(id: owner.id).update_all(name: "Uncommitted provider post effect")
        raise IOError, "Interrupted nested post work"
      end
      owner.expects(:broadcast_sync_complete).never

      Sync.transaction do
        sync.stub(:syncable, owner) do
          owner.stub(:perform_post_sync, failing) do
            assert_raises(IOError) { sync.finalize_if_all_children_finalized }
          end
        end
        assert_equal original_name, owner.reload.name
        assert sync.reload.failed?
        assert_equal "Original failure", sync.error
        assert_equal finished_at, sync.provider_work_finished_at
        assert_nil sync.post_sync_completed_at
      end
    end
  end

  test "a rollback after broadcasting retries database work without claiming exactly-once external delivery" do
    owner = accounts(:depository)
    original_name = owner.name
    sync = Sync.create!(syncable: owner, status: "completed")
    deliveries = 0
    post_work = -> { Account.where(id: owner.id).update_all(name: "Committed after retry") }
    broadcast = -> { deliveries += 1 }
    failed_marker = ->(*_arguments) { raise IOError, "Marker write failed" }

    sync.stub(:syncable, owner) do
      owner.stub(:perform_post_sync, post_work) do
        owner.stub(:broadcast_sync_complete, broadcast) do
          sync.stub(:update!, failed_marker) { assert_raises(IOError) { sync.finalize_if_all_children_finalized } }
          assert_equal original_name, owner.reload.name
          assert_nil sync.reload.post_sync_completed_at
          assert_equal 1, deliveries

          sync.finalize_if_all_children_finalized
          assert_equal 2, deliveries
          assert_equal "Committed after retry", owner.reload.name
          assert sync.reload.post_sync_completed_at
        end
      end
    end
  end
end
