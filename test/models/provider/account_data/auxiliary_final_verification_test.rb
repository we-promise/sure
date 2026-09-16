require "test_helper"
require "timeout"
require_relative "../../../support/retained_logo_test_helper"

class Provider::AccountData::AuxiliaryFinalVerificationTest < ActiveSupport::TestCase
  include RetainedLogoTestHelper
  self.use_transactional_tests = false

  Copier = Provider::AccountData::AuxiliaryCopier
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "a completed byte sweep has a read-only database final check under the original permit" do
    with_retained_logo do |context|
      finish_retained_logo(context)
      Fence.with_exclusive(context.item) do
        expected = verify_all_pages(context)
        before = logo_snapshot(context)
        financial = context.account.reload.attributes
        ActiveStorage::Blob.any_instance.expects(:download_chunk).never
        ActiveStorage::Blob.any_instance.expects(:download).never

        ApplicationRecord.transaction do
          result = logo_copier(context).verify_retained_context!(family: context.family, expected_context: expected)
          assert_equal expected, result
          assert result.frozen?
          assert result.fetch("copy").frozen?
          assert_equal before, logo_snapshot(context)
          assert_equal financial, context.account.reload.attributes
          assert context.control.reload.quiescing?
          assert context.connection.reload.disabled?
        end

        assert_equal before, logo_snapshot(context)
      end
    end
  end

  test "final verification requires the caller transaction and actual exclusive permit" do
    with_retained_logo do |context|
      finish_retained_logo(context)
      expected = verify_all_pages(context)
      before = logo_snapshot(context)
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never

      Fence.with_exclusive(context.item) do
        assert_raises(ArgumentError) do
          logo_copier(context).verify_retained_context!(family: context.family, expected_context: expected)
        end
      end
      ApplicationRecord.transaction do
        assert_raises(Fence::InvalidSource) do
          logo_copier(context).verify_retained_context!(family: context.family, expected_context: expected)
        end
      end

      assert_equal before, logo_snapshot(context)
    end
  end

  test "source target and blob metadata drift after the byte sweep cannot pass final verification" do
    with_retained_logo do |context|
      finish_retained_logo(context)
      Fence.with_exclusive(context.item) do
        expected = verify_all_pages(context)
        before = logo_snapshot(context)
        ActiveStorage::Blob.any_instance.expects(:download_chunk).never
        mutations = [
          -> { context.item.logo_attachment.update_columns(created_at: 1.day.ago) },
          -> { context.connection.logo_attachment.update_columns(created_at: 1.day.ago) },
          -> { context.blob.update_columns(metadata: { "changed_after_verification" => true }) }
        ]

        mutations.each do |mutate|
          ApplicationRecord.transaction(requires_new: true) do
            mutate.call
            assert_raises(Copier::Conflict) do
              logo_copier(context).verify_retained_context!(family: context.family, expected_context: expected)
            end
            raise ActiveRecord::Rollback
          end
        end

        assert_equal before, logo_snapshot(context)
      end
    end
  end

  test "final verification refuses a different original context and never initializes a lost checkpoint" do
    with_retained_logo do |context|
      finish_retained_logo(context)
      Fence.with_exclusive(context.item) do
        expected = verify_all_pages(context)
        before = logo_snapshot(context)
        ActiveStorage::Blob.any_instance.expects(:download_chunk).never
        changed = expected.deep_dup
        changed.fetch("copy")["copy_run_id"] = SecureRandom.uuid
        ApplicationRecord.transaction do
          [ changed, expected.merge("checkpoint_id" => SecureRandom.uuid), expected.merge("content_sha256" => "0" * 64),
            expected.except("target_attachment"), expected.except("limit") ].each do |invalid|
            assert_raises(Copier::Conflict) do
              logo_copier(context).verify_retained_context!(family: context.family, expected_context: invalid)
            end
          end
        end
        assert_equal before, logo_snapshot(context)

        ApplicationRecord.transaction(requires_new: true) do
          logo_checkpoint(context).delete
          assert_no_difference "ProviderSyncCheckpoint.count" do
            assert_raises(Copier::Conflict) do
              logo_copier(context).verify_retained_context!(family: context.family, expected_context: expected)
            end
          end
          raise ActiveRecord::Rollback
        end
        assert_equal before, logo_snapshot(context)
      end
    end
  end

  test "archive bytes changed after a successful source sweep cannot pass the final database checksum" do
    with_retained_logo do |context|
      finish_retained_logo(context)
      Fence.with_exclusive(context.item) do
        expected = verify_all_pages(context)
        before = logo_snapshot(context)
        ActiveStorage::Blob.any_instance.expects(:download_chunk).never

        ApplicationRecord.transaction(requires_new: true) do
          batch = logo_batches(context).first
          # Simulate stored evidence corruption beyond the normal immutable model API.
          batch.update_columns(payload: batch.payload.merge("data" => Base64.strict_encode64("x" * 1024)))
          assert_raises(Copier::Conflict) do
            logo_copier(context).verify_retained_context!(family: context.family, expected_context: expected)
          end
          raise ActiveRecord::Rollback
        end

        assert_equal before, logo_snapshot(context)
      end
    end
  end

  test "explicitly absent logos have a final database check without manufacturing attachment rows" do
    with_retained_logo(bytes: nil) do |context|
      finish_retained_logo(context)
      Fence.with_exclusive(context.item) do
        expected = verify_all_pages(context)
        ActiveStorage::Blob.any_instance.expects(:download_chunk).never
        assert_no_difference [ "ActiveStorage::Attachment.count", "ActiveStorage::Blob.count", "IngestionBatch.count" ] do
          ApplicationRecord.transaction do
            assert_equal expected, logo_copier(context).verify_retained_context!(family: context.family, expected_context: expected)
          end
        end
      end
    end
  end

  test "final verification holds source target blob checkpoint and archive rows until outer commit" do
    skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
    with_retained_logo do |context|
      finish_retained_logo(context)
      Fence.with_exclusive(context.item) do
        expected = verify_all_pages(context)
        ActiveStorage::Blob.any_instance.expects(:download_chunk).never
        ApplicationRecord.transaction do
          logo_copier(context).verify_retained_context!(family: context.family, expected_context: expected)

          assert_row_pinned(ActiveStorage::Attachment, context.item.logo_attachment.id)
          assert_row_pinned(ActiveStorage::Attachment, context.connection.logo_attachment.id)
          assert_row_pinned(ActiveStorage::Blob, context.blob.id)
          assert_row_pinned(ProviderSyncCheckpoint, logo_checkpoint(context).id)
          logo_batches(context).pluck(:id).each { |id| assert_row_pinned(IngestionBatch, id) }
        end
      end
    end
  end

  private
    def verify_all_pages(context)
      cursor = nil
      10.times do
        page = logo_copier(context).verify_retained_page(family: context.family, cursor: cursor, limit: 1)
        return page.context if page.complete
        cursor = page.next_cursor
      end
      flunk "Retained logo verification did not finish within fixture bounds"
    end

    def assert_row_pinned(model, id)
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ApplicationRecord.transaction do
            model.where(id: id).lock("FOR UPDATE NOWAIT").pick(:id)
            :unlocked
          end
        rescue ActiveRecord::LockWaitTimeout
          :locked
        end
      end
      assert_equal :locked, Timeout.timeout(5) { worker.value }, "Expected #{model.name} row to remain pinned"
    ensure
      if worker
        worker.kill if worker.alive?
        worker.join
      end
    end
end
