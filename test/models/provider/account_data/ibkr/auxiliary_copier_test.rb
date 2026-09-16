require "test_helper"
require "stringio"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::Ibkr::AuxiliaryCopierTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  Copier = Provider::AccountData::Ibkr::AuxiliaryCopier

  test "bounded copy and verification preserve original attachment blob and financial IDs with encrypted recovery bytes" do
    with_logo do
      source_attachment = @item.logo_attachment.attributes
      source_blob = @blob.attributes
      control_before = @control.attributes
      source_before = @item.attributes
      financial_ids = families(:empty).accounts.order(:id).pluck(:id)
      copier = Copier.new(control: @control, chunk_bytes: 1024, chunks_per_run: 1)
      first = copier.run
      assert_equal "copy", first.state.fetch("phase")
      assert_equal 1, first.state.fetch("copied_chunks")
      assert_equal 1, archive_batches.count
      assert_not @connection.logo.attached?
      checkpoint = nil
      assert_no_enqueued_jobs do
        assert_no_difference [ "Account.count", "Entry.count", "Balance.count", "ActiveStorage::Blob.count" ] do
          assert_difference "ActiveStorage::Attachment.count", 1 do
            checkpoint = finish(copier)
          end
        end
      end
      assert_equal @bytes, copier.each_archived_chunk.to_a.join.b
      target = @connection.reload.logo_attachment
      assert_equal @blob.id, target.blob_id
      assert_not_equal source_attachment.fetch("id"), target.id
      assert_equal source_attachment, @item.reload.logo_attachment.attributes
      assert_equal source_blob, @blob.reload.attributes
      assert_equal source_before, @item.attributes
      assert_equal control_before, @control.reload.attributes
      assert_equal financial_ids, families(:empty).accounts.order(:id).pluck(:id)
      assert @connection.reload.disabled?
      assert_not_includes ProviderConnection.syncable, @connection
      assert checkpoint.state.fetch("requires_final_reverification")
      assert_not checkpoint.state.fetch("source_quiesced_across_calls")
      assert_provider_column_encrypted(checkpoint, :state, "private-logo.png")
      archive_batches.each do |batch|
        assert_provider_column_encrypted(batch, :payload, Base64.strict_encode64(@bytes.byteslice(0, 1024)))
        assert_nil batch.sync_id
        assert_not batch.complete?
        assert_equal "migration", batch.origin_kind
      end
      assert_no_difference [ "IngestionBatch.count", "ActiveStorage::Attachment.count" ] do
        assert_equal "complete", copier.run.state.fetch("phase")
      end
    end
  end

  test "a storage interruption resumes at the next durable chunk without recopying previous chunks" do
    with_logo do
      copier = Copier.new(control: @control, chunk_bytes: 1024, chunks_per_run: 1)
      copier.run
      ActiveStorage::Blob.any_instance.expects(:download_chunk).with(1024...2048).raises(IOError, "storage unavailable")
      assert_raises(IOError) { copier.run }
      ActiveStorage::Blob.any_instance.unstub(:download_chunk)
      assert_equal 1, archive_batches.count
      assert_equal 1, checkpoint.reload.state.fetch("copied_chunks")
      # A new worker honors the persisted 1024-byte capture plan even if its
      # constructor uses the default chunk size.
      resumed = Copier.new(control: @control, chunks_per_run: 1)
      assert_equal "complete", finish(resumed).state.fetch("phase")
      assert_equal @bytes, resumed.each_archived_chunk.to_a.join.b
      assert_equal 3, archive_batches.count
    end
  end

  test "absent logo is explicit verified evidence without attachments or blob reads" do
    with_logo(bytes: nil) do
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never
      assert_no_difference [ "ActiveStorage::Attachment.count", "ActiveStorage::Blob.count", "IngestionBatch.count" ] do
        result = finish(Copier.new(control: @control))
        manifest = Provider::AccountData::MigrationValue.decode(result.state.fetch("manifest"))
        assert_nil manifest.fetch("attachment")
        assert_nil manifest.fetch("blob")
        assert_equal "complete", result.state.fetch("phase")
      end
      assert_not @connection.logo.attached?
    end
  end

  test "a different target logo is preserved and blocks linking the copied source" do
    with_logo do
      other = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("different"), filename: "different.png", content_type: "image/png", identify: false)
      @connection.logo.attach(other)
      target_id = @connection.logo_attachment.id
      copier = Copier.new(control: @control, chunk_bytes: 1024)
      copier.run
      assert_raises(Copier::Conflict) { copier.run }
      assert_equal target_id, @connection.reload.logo_attachment.id
      assert_equal other.id, @connection.logo_attachment.blob_id
      assert_equal @blob.id, @item.reload.logo_attachment.blob_id
    ensure
      ActiveStorage::Attachment.where(blob_id: other.id).delete_all if other
      other&.purge
    end
  end

  test "source metadata changes block the old capture and never manufacture a new source revision" do
    with_logo do
      copier = Copier.new(control: @control, chunk_bytes: 1024, chunks_per_run: 1)
      copier.run
      original_state = checkpoint.state
      @blob.update!(metadata: @blob.metadata.merge("changed" => true))
      assert_raises(Copier::SourceChanged) { copier.run }
      assert_equal original_state, checkpoint.reload.state
      assert_not @connection.logo.attached?
    end
  end

  test "source bytes must match the captured storage checksum and every archived chunk" do
    with_logo do
      copier = Copier.new(control: @control, chunk_bytes: 1024)
      copier.run
      ActiveStorage::Blob.any_instance.expects(:download_chunk).with(0...1024).returns("x" * 1024)
      assert_raises(Copier::Conflict) { copier.run }
      assert_not @connection.logo.attached?
      assert_equal "verify", checkpoint.reload.state.fetch("phase")
    end
  end

  test "full archive integrity is checked before recovery yields any bytes" do
    with_logo do
      copier = Copier.new(control: @control, chunk_bytes: 1024)
      finish(copier)
      first = archive_batches.order(:sequence).first
      first.update_columns(payload: first.payload.merge("data" => Base64.strict_encode64("x" * 1024)))
      yielded = []
      assert_raises(Copier::Conflict) { copier.each_archived_chunk { |bytes| yielded << bytes } }
      assert_empty yielded
    end
  end

  test "final reverification supports same-item exclusive fence reentry without changing control ownership" do
    with_logo do
      copier = Copier.new(control: @control, chunk_bytes: 1024)
      finish(copier)
      @control.update!(state: "quiescing")
      before = @control.attributes
      Provider::AccountData::LegacyWriterFence.with_exclusive(@item) do
        assert_equal "verify", copier.restart_verification!.state.fetch("phase")
        assert_equal "complete", copier.run.state.fetch("phase")
      end
      assert_equal before, @control.reload.attributes
      assert @connection.reload.disabled?
    end
  end

  test "active ownership enabled targets and transaction-wrapped storage reads are rejected" do
    with_logo do
      copier = Copier.new(control: @control)
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never
      @control.update!(state: "active")
      assert_raises(Copier::Conflict) { copier.run }
      @control.update!(state: "shadow")
      @connection.update!(status: "good")
      assert_raises(Copier::Conflict) { copier.run }
      @connection.update!(status: "disabled")
      ApplicationRecord.transaction do
        assert_raises(ArgumentError) { copier.run }
      end
      assert_not @connection.logo.attached?
    end
  end

  test "unknown attachment schema and oversize blobs are rejected before storage access" do
    with_logo do
      copier = Copier.new(control: @control)
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never
      @blob.update_columns(byte_size: Copier::MAX_BYTES + 1)
      assert_raises(Copier::Conflict) { copier.run }
      @blob.update_columns(byte_size: @bytes.bytesize)
      columns = ActiveStorage::Blob.column_names
      ActiveStorage::Blob.stubs(:column_names).returns(columns + [ "unreviewed_private_data" ])
      assert_raises(Copier::Conflict) { copier.run }
    end
  end

  private
    def with_logo(bytes: ("\x00\xFFlogo-data".b * 250))
      with_provider_encryption do
        DebugLogEntry.stubs(:capture)
        @bytes = bytes
        @item = IbkrItem.create!(family: families(:empty), name: "IBKR auxiliary test", query_id: "query", token: "private-token")
        if bytes
          @blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: "private-logo.png", content_type: "image/png", identify: false)
          @item.logo.attach(@blob)
        end
        main = Provider::AccountData::MigrationCopier.new(provider_key: "ibkr", legacy_item_id: @item.id)
        4.times { break if main.run.shadow? }
        @control = main.control.reload
        assert @control.shadow?
        @connection = @control.provider_connection
        clear_enqueued_jobs
        yield
      ensure
        if @connection
          ActiveStorage::Attachment.where(record_type: "ProviderConnection", record_id: @connection.id).delete_all
          @connection.provider_sync_checkpoints.destroy_all
          ProviderMigrationAccountBinding.where(family_id: @control.family_id,
            provider_migration_mapping_id: @control.provider_migration_mappings.select(:id)).delete_all
          @connection.ingestion_batches.destroy_all
          @control.provider_migration_mappings.destroy_all
          @control.destroy!
          @connection.destroy!
        end
        ActiveStorage::Attachment.where(record_type: "IbkrItem", record_id: @item.id).delete_all if @item
        @item&.destroy!
        @blob&.purge
        clear_enqueued_jobs
      end
    end

    def checkpoint
      @connection.provider_sync_checkpoints.find_by!(stream: Copier::STREAM)
    end

    def archive_batches
      @connection.ingestion_batches.where(stream: Copier::STREAM)
    end

    def finish(copier)
      70.times do
        result = copier.run
        return result if result.state.fetch("phase") == "complete"
      end
      flunk "Auxiliary copy did not finish within its fixture bound"
    end
end
