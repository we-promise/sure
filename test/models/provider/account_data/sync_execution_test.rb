require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::SyncExecutionTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  Execution = Provider::AccountData::SyncExecution

  setup do
    ProviderConnection.any_instance.stubs(:perform_post_sync)
    ProviderConnection.any_instance.stubs(:broadcast_sync_complete)
    Sentry.stubs(:capture_exception)
  end

  test "admission starts the sync and owns its lease before entering provider work" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!

      assert_no_difference "Sync.count" do
        Execution.new(sync).perform do |execution|
          current = Sync.find(sync.id)
          leased = ProviderConnection.find(connection.id)
          assert current.syncing?
          assert current.syncing_at
          assert_equal 1, current.provider_execution_revision
          assert_equal current.provider_execution_revision, execution.revision
          assert_equal sync.id, leased.lease_sync_id
          assert_equal execution.lease_owner, leased.lease_owner
          assert_equal execution.writer_epoch, leased.writer_epoch
          assert leased.lease_expires_at > Time.current
          assert_equal :owned, execution.fenced { :owned }
          assert execution.finish_work!
          assert execution.finalize!
        end
      end

      assert sync.reload.completed?
      assert sync.provider_work_finished_at
      assert sync.post_sync_completed_at
      assert_nil connection.reload.lease_sync_id
      assert_nil connection.lease_owner
      assert_nil connection.lease_expires_at
    end
  end

  test "failed lease persistence rolls back the sync start and execution revision" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      before = execution_state(sync)
      execution = Execution.new(sync)
      execution.connection.expects(:update!).with(has_entries(lease_sync_id: sync.id))
        .raises(IOError, "lease persistence interrupted")

      assert_raises(IOError) do
        execution.perform { flunk "provider work ran without a persisted lease" }
      end

      assert_equal before, execution_state(sync)
    end
  end

  test "an expired same-sync takeover preserves the fetch attempt and observation window" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!(provider_attempt: 4,
        window_start_date: 40.days.ago.to_date, window_end_date: 2.days.ago.to_date)
      original_window = sync.attributes.slice("created_at", "window_start_date", "window_end_date", "provider_attempt")
      first = nil
      Execution.new(sync).perform { |execution| first = execution }
      started_at = sync.reload.syncing_at

      second = nil
      assert_no_difference "Sync.count" do
        second = replace_expired_worker(sync)
      end

      assert_equal original_window, sync.reload.attributes.slice(*original_window.keys)
      assert_equal started_at, sync.syncing_at
      assert_equal first.revision + 1, second.revision
      assert_equal first.writer_epoch + 1, second.writer_epoch
      assert_not_equal first.lease_owner, second.lease_owner
      assert_equal second.lease_owner, connection.reload.lease_owner
      assert_equal sync.id, connection.lease_sync_id
      assert sync.syncing?
      assert_nil sync.provider_work_finished_at
    end
  end

  test "a replaced worker cannot publish settle finalize or release its replacement" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      replacement_state = nil

      Execution.new(sync).perform do |old|
        replacement = replace_expired_worker(sync)
        replacement_state = execution_state(sync)

        assert_raises(Provider::AccountData::StaleWriter) do
          old.fenced { flunk "replaced worker entered publication" }
        end
        assert_not old.transition { flunk "replaced worker entered a state transition" }
        assert_not old.finish_work!
        assert_not old.finalize!
        assert_equal replacement_state, execution_state(sync)
        assert_equal replacement.lease_owner, connection.reload.lease_owner
      end

      # Leaving the old public perform block invokes its cleanup path too.
      assert_equal replacement_state, execution_state(sync)
    end
  end

  test "a late provider exception cannot fail a replacement of the same logical sync" do
    assert_replaced_worker_cannot_settle(IOError.new("old response failed"))
  end

  test "a late provider deferral cannot reschedule a replacement or advance its fetch attempt" do
    SyncJob.expects(:set).never
    assert_replaced_worker_cannot_settle(Provider::AccountData::DeferredPage.new(resume_at: 30.seconds.from_now))
  end

  test "a duplicate job leaves a live execution and its lease unchanged" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      ProviderConnection.any_instance.expects(:perform_sync).never

      Execution.new(sync).perform do |_execution|
        before = execution_state(sync)
        Sync.find(sync.id).perform
        assert_equal before, execution_state(sync)
      end
    end
  end

  test "an interrupt retains unfinished work and its lease for expired-worker recovery" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      ProviderConnection.any_instance.expects(:perform_post_sync).never
      Sentry.expects(:capture_exception).never
      interrupted_work = ->(_current) { raise Interrupt, "worker stopped" }

      sync.stub(:syncable, connection) do
        connection.stub(:perform_sync, interrupted_work) do
          assert_raises(Interrupt) { sync.perform }
        end
      end

      assert sync.reload.syncing?
      assert_equal 0, sync.provider_attempt
      assert_nil sync.provider_work_finished_at
      assert_nil sync.post_sync_completed_at
      assert_nil sync.error
      assert_nil sync.provider_execution
      assert_equal sync.id, connection.reload.lease_sync_id
      assert connection.lease_owner
      assert connection.lease_expires_at
      original_revision = sync.provider_execution_revision
      replacement = replace_expired_worker(sync)
      assert_equal original_revision + 1, replacement.revision
      assert_equal 0, sync.reload.provider_attempt
    end
  end

  test "a queued sync with a deleted connection fails without provider or post-sync work" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      ProviderConnection.where(id: connection.id).delete_all
      ProviderConnection.any_instance.expects(:perform_sync).never
      ProviderConnection.any_instance.expects(:perform_post_sync).never

      Sync.find(sync.id).perform

      assert sync.reload.failed?
      assert sync.failed_at
      assert_equal "Syncable record was deleted", sync.error
      assert_equal 1, sync.provider_execution_revision
      assert_nil sync.syncing_at
      assert_nil sync.provider_work_finished_at
      assert_nil sync.post_sync_completed_at
      assert_not_includes recovery_ids, sync.id
    end
  end

  test "admission rechecks a deleted connection even when the worker cached its receiver" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      execution = Execution.new(sync)
      assert_equal connection.id, execution.connection.id
      ProviderConnection.where(id: connection.id).delete_all
      ProviderConnection.any_instance.expects(:perform_post_sync).never

      execution.perform { flunk "Deleted cached owner cannot enter provider work" }

      assert sync.reload.failed?
      assert_equal "Syncable record was deleted", sync.error
      assert_nil sync.provider_work_finished_at
      assert_nil sync.post_sync_completed_at
    end
  end

  test "a queued sync deleted before its admission lock leaves the connection untouched" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      execution = Execution.new(sync)
      before = connection.reload.attributes
      Sync.where(id: sync.id).delete_all

      execution.perform { flunk "A deleted Sync cannot acquire a provider execution" }

      assert_equal before, connection.reload.attributes
      assert_not Sync.exists?(id: sync.id)
    end
  end

  test "admission does not mistake unrelated missing records for deletion of its owner" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      before = execution_state(sync)
      [ "ExternalAccount", "ProviderConnection" ].each do |model|
        execution = Execution.new(sync)
        missing = ActiveRecord::RecordNotFound.new("another lookup failed", model, "id", SecureRandom.uuid)
        execution.connection.stub(:with_lock, -> { raise missing }) do
          caught = assert_raises(ActiveRecord::RecordNotFound) do
            execution.perform { flunk "An unrelated lookup failed before provider work" }
          end
          assert_same missing, caught
        end
      end

      assert_equal before, execution_state(sync)
    end
  end

  test "missing-owner settlement does not swallow an unrelated error from parent finalization" do
    with_provider_encryption do
      connection = create_provider_connection
      parent = connection.family.syncs.create!(status: "syncing")
      sync = connection.syncs.create!(parent: parent)
      ProviderConnection.where(id: connection.id).delete_all
      missing = ActiveRecord::RecordNotFound.new("parent lookup failed", "ProviderConnection", "id")
      parent.expects(:finalize_if_all_children_finalized).raises(missing)

      Sync.stub(:find_by, parent) do
        caught = assert_raises(ActiveRecord::RecordNotFound) { Sync.find(sync.id).perform }
        assert_same missing, caught
      end

      assert sync.reload.failed?
      assert_nil sync.post_sync_completed_at
    end
  end

  test "orphan settlement preserves terminal rows and does not enqueue endless post work" do
    with_provider_encryption do
      connection = create_provider_connection
      terminal = %w[failed completed stale].map do |status|
        connection.syncs.create!(status: status, provider_execution_revision: 2, error: "retained diagnostic")
      end
      ProviderConnection.where(id: connection.id).delete_all
      ProviderConnection.any_instance.expects(:perform_sync).never
      ProviderConnection.any_instance.expects(:perform_post_sync).never

      terminal.each do |sync|
        before = sync.reload.attributes
        Sync.find(sync.id).perform
        Execution.expire!(Sync.find(sync.id))
        assert_equal before, sync.reload.attributes
      end
      assert_empty recovery_ids & terminal.map(&:id)
    end
  end

  test "cleaner settles expired orphan rows while preserving a freshly renewed orphan window" do
    with_provider_encryption do
      connection = create_provider_connection
      expired = connection.syncs.create!(status: "syncing", provider_execution_revision: 2, created_at: 25.hours.ago)
      renewed = connection.syncs.create!(status: "syncing", provider_execution_revision: 2, created_at: 25.hours.ago)
      Sync.where(id: renewed.id).update_all(created_at: 1.hour.ago)
      before_renewed = Sync.find(renewed.id).attributes
      ProviderConnection.where(id: connection.id).delete_all
      ProviderConnection.any_instance.expects(:perform_post_sync).never

      Execution.expire!(expired)
      Execution.expire!(renewed)

      assert expired.reload.stale?
      assert_equal 3, expired.provider_execution_revision
      assert_equal "Syncable record was deleted", expired.error
      assert_nil expired.provider_work_finished_at
      assert_nil expired.post_sync_completed_at
      assert_equal before_renewed, renewed.reload.attributes
    end
  end

  test "cleaner handles a connection deleted between discovery and its row lock" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!(status: "syncing", provider_execution_revision: 2, created_at: 25.hours.ago)
      discovered = ProviderConnection.find(connection.id)
      ProviderConnection.where(id: connection.id).delete_all
      ProviderConnection.any_instance.expects(:perform_post_sync).never

      # Supply the actual previously discovered receiver; its real lock! reload
      # must observe deletion rather than treating cached attributes as proof.
      ProviderConnection.stub(:find_by, discovered) { Execution.expire!(sync) }

      assert sync.reload.stale?
      assert_equal 3, sync.provider_execution_revision
      assert_equal "Syncable record was deleted", sync.error
      assert_nil sync.post_sync_completed_at
    end
  end

  test "cleaner leaves the connection alone when its discovered sync was deleted" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!(status: "syncing", created_at: 25.hours.ago)
      before = connection.reload.attributes
      Sync.where(id: sync.id).delete_all

      Execution.expire!(sync)

      assert_equal before, connection.reload.attributes
      assert_not Sync.exists?(id: sync.id)
    end
  end

  test "cleaner propagates unrelated missing-record failures" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!(status: "syncing", created_at: 25.hours.ago)
      before = execution_state(sync)
      missing = ActiveRecord::RecordNotFound.new("another lookup failed", "ExternalAccount", "id", SecureRandom.uuid)
      ProviderConnection.stub(:find_by, connection) do
        connection.stub(:with_lock, -> { raise missing }) do
          assert_same missing, assert_raises(ActiveRecord::RecordNotFound) { Execution.expire!(sync) }
        end
      end

      assert_equal before, execution_state(sync)
    end
  end

  test "recovery of finished provider work finalizes once without HTTP or a new writer epoch" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!(provider_attempt: 3)
      Execution.new(sync).perform { |execution| assert execution.finish_work! }
      before = execution_state(sync)
      assert sync.reload.syncing?
      assert_nil sync.post_sync_completed_at
      ProviderConnection.any_instance.expects(:perform_sync).never
      ProviderConnection.any_instance.expects(:perform_post_sync).once
      ProviderConnection.any_instance.expects(:broadcast_sync_complete).once

      Sync.find(sync.id).perform
      marker = sync.reload.post_sync_completed_at
      assert sync.completed?
      assert marker
      Sync.find(sync.id).perform

      assert_equal marker, sync.reload.post_sync_completed_at
      assert_equal before.fetch(:sync).fetch("provider_work_finished_at"), sync.provider_work_finished_at
      assert_equal before.fetch(:sync).fetch("provider_execution_revision"), sync.provider_execution_revision
      assert_equal 3, sync.provider_attempt
      assert_equal before.fetch(:connection), connection.reload.attributes
    end
  end

  test "failed post work is retried from its work marker without fetching again" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      Execution.new(sync).perform { |execution| execution.finish_work! }
      before = execution_state(sync)
      ProviderConnection.any_instance.expects(:perform_sync).never
      ProviderConnection.any_instance.expects(:perform_post_sync).twice
        .raises(IOError, "post work interrupted").then.returns(nil)
      ProviderConnection.any_instance.expects(:broadcast_sync_complete).once

      assert_raises(IOError) { Sync.find(sync.id).perform }
      assert_equal before, execution_state(sync)
      Sync.find(sync.id).perform

      assert sync.reload.completed?
      assert sync.post_sync_completed_at
      assert_equal before.fetch(:sync).fetch("provider_work_finished_at"), sync.provider_work_finished_at
      assert_equal before.fetch(:connection), connection.reload.attributes
    end
  end

  test "recovery selects expired bound workers and rechecks a renewed lease when its job starts" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = interrupted_sync(connection, lease_expires_at: 1.minute.ago)
      live = interrupted_sync(create_provider_connection, lease_expires_at: 5.minutes.from_now)
      unbound = create_provider_connection.syncs.create!(status: "syncing")
      too_old = interrupted_sync(create_provider_connection, created_at: 25.hours.ago, lease_expires_at: 1.hour.ago)

      queued = recovery_ids
      assert_includes queued, sync.id
      assert_not_includes queued, live.id
      assert_not_includes queued, unbound.id
      assert_not_includes queued, too_old.id

      connection.update!(lease_expires_at: 5.minutes.from_now)
      before = execution_state(sync)
      ProviderConnection.any_instance.expects(:perform_sync).never
      Sync.find(sync.id).perform
      assert_equal before, execution_state(sync)
    end
  end

  test "recovery waits for children and retries terminal post work without reviving failed provider work" do
    with_provider_encryption do
      connection = create_provider_connection
      failed = connection.syncs.create!(status: "failed", provider_execution_revision: 1,
        error: "original failure", failed_at: Time.current.change(usec: 0))
      child = accounts(:depository).syncs.create!(parent: failed)
      ProviderConnection.any_instance.expects(:perform_sync).never

      assert_not_includes recovery_ids, failed.id
      child.update!(status: "completed")
      assert_includes recovery_ids, failed.id
      Sync.find(failed.id).perform

      assert failed.reload.failed?
      assert_equal "original failure", failed.error
      assert failed.post_sync_completed_at
      assert_not_includes recovery_ids, failed.id
      assert_equal 0, connection.reload.writer_epoch
    end
  end

  test "cleaner reloads an apparent expired sync before deciding to invalidate its lease" do
    with_provider_encryption do
      connection = create_provider_connection
      stale_view = interrupted_sync(connection, created_at: 25.hours.ago, lease_expires_at: 1.minute.ago)
      Sync.where(id: stale_view.id).update_all(created_at: 1.hour.ago)
      before = execution_state(stale_view)

      Execution.expire!(stale_view)

      assert_equal before, execution_state(stale_view)
    end
  end

  test "cleaner cannot mark a freshly terminal sync stale or revoke its current lease" do
    with_provider_encryption do
      connection = create_provider_connection
      stale_view = interrupted_sync(connection, created_at: 25.hours.ago, lease_expires_at: 1.minute.ago)
      Sync.where(id: stale_view.id).update_all(status: "completed", post_sync_completed_at: Time.current)
      before = execution_state(stale_view)
      ProviderConnection.any_instance.expects(:perform_post_sync).never

      Execution.expire!(stale_view)

      assert_equal before, execution_state(stale_view)
    end
  end

  test "cleaner revokes a genuinely stale worker and its later job cannot restart it" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = interrupted_sync(connection, created_at: 25.hours.ago, lease_expires_at: 5.minutes.from_now)
      epoch = connection.writer_epoch
      revision = sync.provider_execution_revision
      ProviderConnection.any_instance.expects(:perform_sync).never
      ProviderConnection.any_instance.expects(:perform_post_sync).never

      Execution.expire!(sync)
      assert sync.reload.stale?
      assert_equal revision + 1, sync.provider_execution_revision
      assert_equal epoch + 1, connection.reload.writer_epoch
      assert_nil connection.lease_sync_id
      assert_nil connection.lease_owner
      assert_nil connection.lease_expires_at
      before = execution_state(sync)
      Sync.find(sync.id).perform

      assert_equal before, execution_state(sync)
      assert_nil sync.post_sync_completed_at
    end
  end

  test "expiring an older sync does not release another sync's lease on the connection" do
    with_provider_encryption do
      connection = create_provider_connection
      old = connection.syncs.create!(status: "syncing", provider_execution_revision: 1, created_at: 25.hours.ago)
      current = interrupted_sync(connection, lease_expires_at: 5.minutes.from_now)
      before = execution_state(current)

      Execution.expire!(old)

      assert old.reload.stale?
      assert_equal before, execution_state(current)
    end
  end

  private
    def execution_state(sync)
      {
        sync: Sync.find(sync.id).attributes,
        connection: ProviderConnection.find(sync.syncable_id).attributes
      }
    end

    def replace_expired_worker(sync)
      ProviderConnection.find(sync.syncable_id).update!(lease_expires_at: 1.second.ago)
      replacement = nil
      # No finish marker models a worker that still has provider work in flight.
      Execution.new(Sync.find(sync.id)).perform { |execution| replacement = execution }
      assert replacement, "the expired bound execution should be recoverable"
      replacement
    end

    def assert_replaced_worker_cannot_settle(error)
      with_provider_encryption do
        connection = create_provider_connection
        sync = connection.syncs.create!(provider_attempt: 2,
          window_start_date: 30.days.ago.to_date, window_end_date: Date.current)
        replacement_state = nil
        provider_work = lambda do |current|
          replace_expired_worker(current)
          replacement_state = execution_state(current)
          raise error
        end
        ProviderConnection.any_instance.expects(:perform_post_sync).never
        Sentry.expects(:capture_exception).never

        sync.stub(:syncable, connection) do
          connection.stub(:perform_sync, provider_work) { sync.perform }
        end

        assert replacement_state
        assert_equal replacement_state, execution_state(sync)
        assert sync.reload.syncing?
        assert_equal 2, sync.provider_attempt
        assert_nil sync.error
        assert_nil sync.resume_at
        assert_nil sync.provider_work_finished_at
        assert_nil sync.post_sync_completed_at
        assert_nil sync.provider_execution
      end
    end

    def interrupted_sync(connection, lease_expires_at:, created_at: 1.hour.ago)
      sync = connection.syncs.create!(status: "syncing", provider_execution_revision: 1,
        created_at: created_at, syncing_at: created_at)
      connection.update!(writer_epoch: 1, lease_sync_id: sync.id,
        lease_owner: SecureRandom.uuid, lease_expires_at: lease_expires_at)
      sync
    end

    def recovery_ids
      queued = []
      SyncJob.stub(:perform_later, ->(sync) { queued << sync.id }) { Execution.recover_stalled! }
      queued
    end
end
