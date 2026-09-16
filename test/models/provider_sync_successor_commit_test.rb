require "test_helper"
require_relative "../support/provider_ingestion_test_helper"

class ProviderSyncSuccessorCommitTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  test "terminal transitions enqueue their successor after commit even after a later diagnostic save" do
    with_queue do |original, successor|
      assert_enqueued_with(job: SyncJob, args: [ successor ]) do
        Sync.transaction do
          original.update!(status: "failed", failed_at: Time.current)
          original.update!(error: "Captured provider failure")
          assert_no_enqueued_jobs(only: SyncJob)
        end
      end
      assert original.reload.failed?
      assert_equal "Captured provider failure", original.error
      assert successor.reload.pending?
    end
  end

  test "rolled back terminal transitions cannot enqueue a successor" do
    with_queue do |original, successor|
      assert_no_enqueued_jobs(only: SyncJob) do
        Sync.transaction do
          original.update!(status: "completed", completed_at: Time.current)
          raise ActiveRecord::Rollback
        end
      end
      assert original.reload.syncing?
      assert successor.reload.pending?
    end
  end

  test "completion does not enqueue a cancelled successor" do
    with_queue do |original, successor|
      successor.update!(cancel_requested_at: Time.current, status: "stale")
      clear_enqueued_jobs
      assert_no_enqueued_jobs(only: SyncJob) { original.update!(status: "completed", completed_at: Time.current) }
    end
  end

  private
    def with_queue
      with_provider_encryption do
        connection = create_provider_connection
        original = connection.syncs.create!(status: "syncing", syncing_at: Time.current)
        successor = connection.syncs.create!(predecessor: original)
        clear_enqueued_jobs
        begin
          yield original, successor
        ensure
          # One statement removes both ends of the same-owner predecessor FK.
          connection.syncs.delete_all
          connection.destroy!
          clear_enqueued_jobs
        end
      end
    end
end
