require "test_helper"
require_relative "../support/provider_ingestion_test_helper"

class ProviderSyncContinuationTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper

  setup do
    ProviderConnection.any_instance.stubs(:perform_post_sync)
    ProviderConnection.any_instance.stubs(:broadcast_sync_complete)
  end

  test "a provider waits durably then resumes the same sync and completes" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      original_created_at = sync.created_at
      resume_at = 10.minutes.from_now.change(usec: 0)
      connection.expects(:perform_sync).with(sync).raises(Provider::AccountData::DeferredPage.new(resume_at: resume_at))
      scheduled = mock("delayed sync")
      SyncJob.expects(:set).with(wait_until: resume_at).returns(scheduled)
      scheduled.expects(:perform_later).with(sync)
      sync.perform

      assert sync.reload.pending?
      assert_equal resume_at, sync.resume_at
      assert_equal 1, sync.provider_attempt
      assert_nil sync.failed_at
      assert_nil sync.error
      assert_nil sync.provider_work_finished_at
      assert_nil sync.completed_at
      assert_no_difference "Sync.count" do
        assert_equal sync.id, connection.sync_later.id
      end

      ProviderConnection.any_instance.expects(:perform_sync).never
      Sync.find(sync.id).perform
      assert sync.reload.pending?
      ProviderConnection.any_instance.unstub(:perform_sync)

      travel_to resume_at do
        ProviderConnection.any_instance.expects(:perform_sync).once
        Sync.find(sync.id).perform
      end
      assert sync.reload.completed?
      assert_equal original_created_at, sync.created_at
      assert_nil sync.resume_at
      assert sync.provider_work_finished_at
    end
  end

  test "account completion cannot finish a provider while its own attempt is still running" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      connection.define_singleton_method(:perform_sync) do |current|
        child = accounts.first.syncs.create!(parent: current, status: "completed")
        child.finalize_if_all_children_finalized
        raise "Provider finalized during dispatch" unless current.reload.syncing?
      end
      external = create_external_account(connection)
      AccountProvider.create!(account: accounts(:depository), external_account: external)
      Account.any_instance.stubs(:perform_post_sync)
      Account.any_instance.stubs(:broadcast_sync_complete)

      sync.perform

      assert sync.reload.completed?, sync.error
      assert sync.provider_work_finished_at
    end
  end

  test "cancelling a delayed sync prevents later polling" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!(resume_at: 1.hour.from_now, provider_attempt: 1)
      assert sync.request_cancel!
      ProviderConnection.any_instance.expects(:perform_sync).never
      travel 2.hours do
        Sync.find(sync.id).perform
      end
      assert sync.reload.stale?
    end
  end

  test "a parent cancellation stops a running provider from scheduling another attempt" do
    with_provider_encryption do
      connection = create_provider_connection
      parent = connection.family.syncs.create!(status: "syncing")
      sync = connection.syncs.create!(parent: parent)
      connection.define_singleton_method(:perform_sync) do |_current|
        parent.update!(cancel_requested_at: Time.current)
        raise Provider::AccountData::DeferredPage.new(resume_at: 10.seconds.from_now)
      end
      SyncJob.expects(:set).never

      sync.perform

      assert sync.reload.stale?
      assert parent.reload.stale?
      assert_equal 0, sync.provider_attempt
    end
  end

  test "deferral cannot revive a sync already marked stale" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      connection.define_singleton_method(:perform_sync) do |current|
        Sync.find(current.id).mark_stale!
        raise Provider::AccountData::DeferredPage.new(resume_at: 10.seconds.from_now)
      end
      SyncJob.expects(:set).never
      sync.perform
      assert sync.reload.stale?
      assert_nil sync.resume_at
    end
  end

  test "a due continuation is requeued without replacing its sync identity" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!(created_at: 20.minutes.ago, resume_at: 10.minutes.ago, provider_attempt: 2)
      SyncJob.expects(:perform_later).with(sync)
      assert_no_difference "Sync.count" do
        assert_equal sync.id, connection.sync_later.id
      end
    end
  end

  test "an excessive deferral fails instead of waiting beyond cleanup retention" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      connection.expects(:perform_sync).raises(Provider::AccountData::DeferredPage.new(resume_at: 2.days.from_now))
      SyncJob.expects(:set).never
      sync.perform
      assert sync.reload.failed?
      assert_nil sync.resume_at
      assert_equal "Provider continuation exceeded its retry boundary", sync.error
    end
  end

  test "a wider request queues a successor without changing an already captured window" do
    with_provider_encryption do
      connection = create_provider_connection
      start_date, end_date = 7.days.ago.to_date, Date.current
      original = connection.syncs.create!(resume_at: 10.minutes.from_now, provider_attempt: 1,
        window_start_date: start_date, window_end_date: end_date)
      successor = nil
      assert_difference "Sync.count", 1 do
        successor = connection.sync_later(window_start_date: 30.days.ago.to_date, window_end_date: end_date)
      end
      assert_equal original.id, successor.predecessor_id
      assert_equal start_date, original.reload.window_start_date
      assert_equal end_date, original.window_end_date
      assert_equal 0, successor.provider_attempt
      assert_nil successor.resume_at
      ProviderConnection.any_instance.expects(:perform_sync).never
      successor.perform
      assert successor.reload.pending?
      assert_nil successor.syncing_at

      assert_no_difference "Sync.count" do
        assert_equal successor.id, connection.sync_later(window_start_date: 60.days.ago.to_date, window_end_date: end_date).id
      end
      assert_equal 60.days.ago.to_date, successor.reload.window_start_date
      assert_equal start_date, original.reload.window_start_date
    end
  end

  test "a terminal predecessor allows its successor to execute its own run" do
    with_provider_encryption do
      connection = create_provider_connection
      original = connection.syncs.create!(status: "completed")
      successor = connection.syncs.create!(predecessor: original)
      connection.expects(:perform_sync).with(successor).once
      successor.perform
      assert successor.reload.completed?
      assert_equal 0, successor.provider_attempt
      assert_not_equal original.id, successor.id
    end
  end

  test "successor dependency cannot reference another provider connection or itself" do
    with_provider_encryption do
      connection = create_provider_connection
      other = create_provider_connection
      original = other.syncs.create!
      successor = connection.syncs.build(predecessor: original)
      assert_not successor.valid?
      assert successor.errors[:predecessor].present?
      assert_database_rejects(successor)

      self_reference = connection.syncs.build(id: SecureRandom.uuid)
      self_reference.predecessor = self_reference
      assert_not self_reference.valid?
      assert self_reference.errors[:predecessor].present?
    end
  end

  test "simultaneous creation timestamps still extend the last queued successor" do
    with_provider_encryption do
      connection = create_provider_connection
      timestamp = Time.current.change(usec: 0)
      original = connection.syncs.create!(id: "ffffffff-ffff-4fff-bfff-ffffffffffff", created_at: timestamp,
        provider_attempt: 1, resume_at: 10.minutes.from_now, window_start_date: 7.days.ago.to_date)
      successor = connection.syncs.create!(id: "00000000-0000-4000-8000-000000000001", created_at: timestamp,
        predecessor: original, window_start_date: 30.days.ago.to_date)

      assert_no_difference "Sync.count" do
        assert_equal successor.id, connection.sync_later(window_start_date: 60.days.ago.to_date).id
      end
      assert_equal 7.days.ago.to_date, original.reload.window_start_date
      assert_equal 60.days.ago.to_date, successor.reload.window_start_date
    end
  end

  test "a predecessor has at most one active successor even if a caller bypasses scheduling" do
    with_provider_encryption do
      connection = create_provider_connection
      original = connection.syncs.create!(provider_attempt: 1)
      first = connection.syncs.create!(predecessor: original)
      duplicate = connection.syncs.build(predecessor: original)
      assert_not duplicate.valid?
      assert duplicate.errors[:predecessor_id].present?
      assert_database_rejects(duplicate, error_class: ActiveRecord::RecordNotUnique)

      first.update!(status: "stale", cancel_requested_at: Time.current)
      replacement = connection.syncs.create!(predecessor: original)
      assert_not_equal first.id, replacement.id
    end
  end

  test "an explicit backfill is retained when an unstarted default request is coalesced" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      backfill_start = 1.year.ago.to_date
      assert_no_difference "Sync.count" do
        assert_equal sync.id, connection.sync_later(window_start_date: backfill_start).id
        assert_equal sync.id, connection.sync_later.id
      end
      assert_equal backfill_start, sync.reload.window_start_date
      assert_nil sync.window_end_date
    end
  end

  test "a frozen default history window cannot absorb an explicit older backfill" do
    with_provider_encryption do
      connection = create_provider_connection
      original = connection.syncs.create!(provider_attempt: 1, resume_at: 10.minutes.from_now)
      successor = nil
      assert_difference "Sync.count", 1 do
        successor = connection.sync_later(window_start_date: 1.year.ago.to_date)
      end
      assert_equal original.id, successor.predecessor_id
      assert_equal 1.year.ago.to_date, successor.window_start_date
      assert_nil original.reload.window_start_date
    end
  end

  test "a successor cannot start after its family cancellation has already committed" do
    with_provider_encryption do
      connection = create_provider_connection
      parent = connection.family.syncs.create!(status: "syncing", cancel_requested_at: Time.current)
      original = connection.syncs.create!(parent: parent, status: "completed")
      successor = connection.syncs.create!(parent: parent, predecessor: original)
      ProviderConnection.any_instance.expects(:perform_sync).never

      successor.perform

      assert successor.reload.stale?
      assert_nil successor.syncing_at
      assert parent.reload.stale?
    end
  end
end
