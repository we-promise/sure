require "test_helper"
require_relative "../../../support/retained_logo_test_helper"

class Provider::AccountData::AuxiliaryCopierTest < ActiveSupport::TestCase
  include RetainedLogoTestHelper
  self.use_transactional_tests = false

  Copier = Provider::AccountData::AuxiliaryCopier

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "reviewed catalog covers exactly all twenty current item logo scopes" do
    manifests = Provider::AccountData::MigrationManifest.all
    declared = manifests.select { |manifest| manifest.item_type.constantize.reflect_on_all_attachments.map(&:name).include?(:logo) }
    assert_equal 20, declared.size
    assert_equal declared.map(&:provider_key).sort, Copier::SUPPORTED_PROVIDER_KEYS.sort
    assert_equal 19, Copier::PROVIDER_KEYS.size
    declared.each do |manifest|
      assert_equal [ "logo" ], manifest.item_type.constantize.reflect_on_all_attachments.map { |attachment| attachment.name.to_s }.sort
      assert_empty manifest.account_type.constantize.reflect_on_all_attachments
    end
    %w[onchain_wallet trade_republic wise].each { |key| assert_raises(ArgumentError) { Copier.stream_for(key) } }
    assert_equal "legacy_ibkr_auxiliary", Copier.stream_for("ibkr")
    assert_equal "legacy_logo_auxiliary", Copier.stream_for("up")
  end

  test "different provider scopes retain exact bytes original IDs and credentials across fresh workers" do
    %w[up plaid].each do |key|
      with_retained_logo(provider_key: key) do |context|
        before = [ context.control.reload.attributes, context.item.reload.attributes, context.account.reload.attributes, context.blob.reload.attributes ]
        first = logo_copier(context).run_retained(family: context.family)
        captured = logo_batches(context).sole.attributes
        resumed = Copier.for(control: context.control, chunks_per_run: 1, chunk_bytes: 4096)
        final = nil
        15.times do
          final = resumed.run_retained(family: context.family, expected_context: first.context)
          break if final.complete?
        end

        assert final.complete?
        assert_equal first.checkpoint_id, final.checkpoint_id
        assert_equal first.context, final.context
        assert_equal 1024, final.context.fetch("chunk_bytes")
        assert_equal captured, IngestionBatch.find(captured.fetch("id")).attributes
        assert_equal context.bytes, resumed.each_archived_chunk.to_a.join.b
        assert_equal before, [ context.control.reload.attributes, context.item.reload.attributes, context.account.reload.attributes, context.blob.reload.attributes ]
        assert_equal context.blob.id, context.connection.reload.logo_attachment.blob_id
        assert_equal "#{context.item.class.name}:#{context.item.id}:logo", logo_checkpoint(context).scope_key
        assert_provider_column_encrypted(logo_checkpoint(context), :state, '"manifest"')
        assert_provider_column_encrypted(logo_batches(context).first, :payload, '"data"')
      end
    end
  end

  test "explicit absent logo completes without reading storage or manufacturing a blob" do
    with_retained_logo(bytes: nil) do |context|
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never
      assert_no_difference [ "ActiveStorage::Blob.count", "ActiveStorage::Attachment.count" ] do
        receipt = finish_retained_logo(context)
        assert_equal 0, receipt.context.fetch("chunks")
        page = logo_copier(context).verify_retained_page(family: context.family)
        assert page.complete
        assert_empty page.rows
        assert_nil Provider::AccountData::MigrationValue.decode(page.context.fetch("target_attachment"))
      end
      assert_empty logo_batches(context)
    end
  end

  test "storage failure resumes the original chunk without transactions across storage reads" do
    with_retained_logo do |context|
      first = logo_copier(context).run_retained(family: context.family)
      before = logo_snapshot(context)
      ActiveStorage::Blob.any_instance.expects(:download_chunk).with(1024...2048).raises(IOError, "interrupted")
      assert_raises(IOError) { logo_copier(context).run_retained(family: context.family, expected_context: first.context) }
      assert_equal before, logo_snapshot(context)
      ActiveStorage::Blob.any_instance.unstub(:download_chunk)
      ActiveStorage::Blob.any_instance.expects(:download_chunk).with do |range|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        range == (1024...2048)
      end.returns(context.bytes.byteslice(1024, 1024))
      result = logo_copier(context).run_retained(family: context.family, expected_context: first.context)
      assert_equal first.checkpoint_id, result.checkpoint_id
      assert_equal 2, result.copied_chunks
    end
  end

  test "a retained checkpoint cannot reinterpret old IBKR format or wrong source family" do
    with_retained_logo do |context|
      finish_retained_logo(context)
      original = logo_snapshot(context)
      assert_raises(Copier::Conflict) { logo_copier(context).verify_retained_page(family: families(:empty)) }
      assert_equal original, logo_snapshot(context)
      checkpoint = logo_checkpoint(context)
      checkpoint.update!(state: checkpoint.state.merge("format" => Provider::AccountData::Ibkr::AuxiliaryCopier::FORMAT))
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never
      assert_raises(Copier::Conflict) { logo_copier(context).run_retained(family: context.family) }
      assert_equal original.fetch(:batches), logo_snapshot(context).fetch(:batches)
    end
  end

  test "lost checkpoint cannot replace retained chunks or reopen copy and legacy ownership" do
    with_retained_logo do |context|
      receipt = logo_copier(context).run_retained(family: context.family)
      ProviderSyncCheckpoint.find(receipt.checkpoint_id).delete
      before = logo_batches(context).map(&:attributes)
      assert_raises(Copier::Conflict) { logo_copier(context).run_retained(family: context.family) }
      assert_raises(Provider::AccountData::MigrationCopier::Conflict) { context.copier.run_quiesced(restart: true) }
      assert_raises(Provider::AccountData::MigrationCopier::Conflict) { context.copier.resume_legacy! }
      assert_equal before, logo_batches(context).map(&:attributes)
    end
  end

  test "source attachment changes and changed storage bytes preserve original receipts" do
    with_retained_logo do |context|
      finish_retained_logo(context)
      original = logo_snapshot(context)
      ActiveStorage::Blob.any_instance.expects(:download_chunk).with(0...1024).returns("x" * 1024)
      assert_raises(Copier::Conflict) { logo_copier(context).verify_retained_page(family: context.family, limit: 1) }
      ActiveStorage::Blob.any_instance.unstub(:download_chunk)
      context.item.logo_attachment.update_columns(created_at: 1.day.ago)
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never
      assert_raises(Copier::SourceChanged) { logo_copier(context).verify_retained_page(family: context.family, limit: 1) }
      assert_equal original.fetch(:checkpoint), logo_checkpoint(context).attributes
      assert_equal original.fetch(:batches), logo_batches(context).map(&:attributes)
    end
  end

  test "independently changed target attachment is neither replaced nor purged" do
    with_retained_logo do |context|
      finish_retained_logo(context)
      original = logo_snapshot(context)
      context.connection.logo_attachment.update_columns(created_at: 1.day.ago)
      changed = context.connection.logo_attachment.reload.attributes
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never
      assert_raises(Copier::Conflict) { logo_copier(context).verify_retained_page(family: context.family) }
      assert_equal changed, context.connection.logo_attachment.reload.attributes
      assert_equal original.fetch(:checkpoint), logo_checkpoint(context).attributes
      assert_equal original.fetch(:batches), logo_batches(context).map(&:attributes)
      assert ActiveStorage::Blob.exists?(context.blob.id)
    end
  end
end
