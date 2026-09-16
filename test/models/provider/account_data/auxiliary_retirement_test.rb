require "test_helper"
require_relative "../../../support/retained_logo_test_helper"

class Provider::AccountData::AuxiliaryRetirementTest < ActiveSupport::TestCase
  include RetainedLogoTestHelper
  self.use_transactional_tests = false

  Copier = Provider::AccountData::AuxiliaryCopier
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
    Provider::AccountData::Up.stubs(:native_ready?).returns(true)
    Provider::Up.expects(:new).never
  end

  test "native retirement removes only the original attachment and replays after legacy rows disappear" do
    with_native_logo do |context|
      archive = retained_bytes(context)
      blob = context.blob.reload.attributes
      financial = context.account.reload.attributes
      source_id = context.item.logo_attachment.id
      target = context.connection.reload.logo_attachment.attributes
      receipt = nil

      Fence.with_exclusive(context.item) do
        copier = logo_copier(context)
        receipt = copier.prepare_retirement(family: context.family)
        assert receipt.frozen?
        assert receipt.values.compact.all?(&:frozen?)
        refute_includes receipt.to_json, context.blob.key
        refute_includes receipt.to_json, context.blob.filename.to_s
        refute_includes receipt.to_json, Base64.strict_encode64(context.bytes)
        ActiveStorage::Blob.any_instance.expects(:download_chunk).never
        ActiveStorage::Blob.expects(:create_and_upload!).never
        assert_no_enqueued_jobs do
          ApplicationRecord.transaction do
            assert_equal receipt, copier.apply_retirement!(family: context.family, receipt: receipt)
            delete_legacy_rows(context)
          end
        end
      end

      refute ActiveStorage::Attachment.exists?(source_id)
      assert_equal target, context.connection.reload.logo_attachment.attributes
      assert_equal blob, context.blob.reload.attributes
      assert_equal financial, context.account.reload.attributes
      assert_equal archive, retained_bytes(context)
      assert_equal receipt, logo_copier(context).verify_retirement!(family: context.family, receipt: JSON.parse(receipt.to_json))
      assert_equal context.bytes, logo_copier(context).each_archived_chunk.to_a.join.b
    end
  end

  test "retirement storage sweep runs without database transactions and verifies every original range" do
    with_native_logo do |context|
      state = logo_checkpoint(context).state
      state.fetch("chunks").times do |index|
        start = index * state.fetch("chunk_bytes")
        length = [ state.fetch("chunk_bytes"), context.bytes.bytesize - start ].min
        ActiveStorage::Blob.any_instance.expects(:download_chunk).with do |range|
          assert_equal 0, ApplicationRecord.connection.open_transactions
          range == (start...(start + length))
        end.returns(context.bytes.byteslice(start, length))
      end
      Fence.with_exclusive(context.item) { logo_copier(context).prepare_retirement(family: context.family) }
      assert ActiveStorage::Attachment.exists?(record_type: "UpItem", record_id: context.item.id, name: "logo")
    end
  end

  test "absent logo is an explicit signed zero-byte retirement without storage or attachment writes" do
    with_native_logo(bytes: nil) do |context|
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never
      Fence.with_exclusive(context.item) do
        copier = logo_copier(context)
        receipt = copier.prepare_retirement(family: context.family)
        assert_nil receipt.fetch("source_attachment_id")
        assert_nil receipt.fetch("target_attachment_id")
        assert_nil receipt.fetch("blob_id")
        assert_no_difference [ "ActiveStorage::Attachment.count", "ActiveStorage::Blob.count" ] do
          ApplicationRecord.transaction do
            copier.apply_retirement!(family: context.family, receipt: receipt)
            delete_legacy_rows(context)
          end
        end
        assert_equal receipt, logo_copier(context).verify_retirement!(family: context.family, receipt: receipt)
      end
    end
  end

  test "outer failure restores attachment and the same held permit can retry atomic application" do
    with_native_logo do |context|
      source = context.item.logo_attachment.attributes
      archive = retained_bytes(context)
      Fence.with_exclusive(context.item) do
        copier = logo_copier(context)
        receipt = copier.prepare_retirement(family: context.family)
        ApplicationRecord.transaction do
          copier.apply_retirement!(family: context.family, receipt: receipt)
          refute ActiveStorage::Attachment.exists?(source.fetch("id"))
          raise ActiveRecord::Rollback
        end
        assert_equal source, ActiveStorage::Attachment.find(source.fetch("id")).attributes
        ApplicationRecord.transaction do
          copier.apply_retirement!(family: context.family, receipt: receipt)
          delete_legacy_rows(context)
        end
        assert_equal receipt, logo_copier(context).verify_retirement!(family: context.family, receipt: receipt)
      end
      assert_equal archive, retained_bytes(context)
    end
  end

  test "capture refuses drifted storage bytes and never deletes either attachment" do
    with_native_logo do |context|
      original = logo_snapshot(context)
      ActiveStorage::Blob.any_instance.expects(:download_chunk).with(0...1024).returns("x" * 1024)
      Fence.with_exclusive(context.item) do
        assert_raises(Copier::Conflict) { logo_copier(context).prepare_retirement(family: context.family) }
      end
      assert_equal original, logo_snapshot(context)
    end
  end

  test "application rejects changed source target and blob metadata after preparation" do
    with_native_logo do |context|
      original = logo_snapshot(context)
      Fence.with_exclusive(context.item) do
        copier = logo_copier(context)
        receipt = copier.prepare_retirement(family: context.family)
        [ context.item.logo_attachment, context.connection.reload.logo_attachment, context.blob ].each do |row|
          assert_raises(Copier::Conflict) do
            ApplicationRecord.transaction do
              row.update_columns(created_at: 1.day.ago)
              copier.apply_retirement!(family: context.family, receipt: receipt)
            end
          end
        end
      end
      assert_equal original, logo_snapshot(context)
    end
  end

  test "application refuses removed or rewritten checkpoint and archive without reconstructing evidence" do
    with_native_logo do |context|
      original = retained_bytes(context)
      Fence.with_exclusive(context.item) do
        copier = logo_copier(context)
        receipt = copier.prepare_retirement(family: context.family)
        assert_raises(Copier::Conflict) do
          ApplicationRecord.transaction do
            logo_checkpoint(context).delete
            copier.apply_retirement!(family: context.family, receipt: receipt)
          end
        end
        assert_raises(Copier::Conflict) do
          ApplicationRecord.transaction do
            checkpoint = logo_checkpoint(context)
            checkpoint.update!(state: checkpoint.state.merge("verified_at" => 1.day.ago.iso8601))
            copier.apply_retirement!(family: context.family, receipt: receipt)
          end
        end
        assert_raises(Copier::Conflict) do
          ApplicationRecord.transaction do
            logo_batches(context).first.delete
            copier.apply_retirement!(family: context.family, receipt: receipt)
          end
        end
      end
      assert_equal original, retained_bytes(context)
      assert ActiveStorage::Attachment.exists?(record_type: "UpItem", record_id: context.item.id, name: "logo")
    end
  end

  test "apply requires the original prepared object and uninterrupted exclusive permit" do
    with_native_logo do |context|
      copier = logo_copier(context)
      assert_raises(Fence::InvalidSource) { copier.prepare_retirement(family: context.family) }
      receipt = nil
      Fence.with_exclusive(context.item) do
        receipt = copier.prepare_retirement(family: context.family)
        assert_raises(Copier::Conflict) do
          ApplicationRecord.transaction { logo_copier(context).apply_retirement!(family: context.family, receipt: receipt) }
        end
      end
      Fence.with_exclusive(context.item) do
        assert_raises(Copier::Conflict) do
          ApplicationRecord.transaction { copier.apply_retirement!(family: context.family, receipt: receipt) }
        end
      end
      assert ActiveStorage::Attachment.exists?(record_type: "UpItem", record_id: context.item.id, name: "logo")
    end
  end

  test "foreign family tampered receipt and target replacement after retirement refuse replay" do
    with_native_logo do |context|
      receipt = nil
      Fence.with_exclusive(context.item) do
        copier = logo_copier(context)
        receipt = copier.prepare_retirement(family: context.family)
        ApplicationRecord.transaction do
          copier.apply_retirement!(family: context.family, receipt: receipt)
          delete_legacy_rows(context)
        end
      end
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never
      assert_raises(Copier::Conflict) { logo_copier(context).verify_retirement!(family: families(:empty), receipt: receipt) }
      assert_raises(Copier::Conflict) do
        logo_copier(context).verify_retirement!(family: context.family, receipt: receipt.merge("blob_id" => SecureRandom.uuid))
      end
      assert_raises(Copier::Conflict) do
        ApplicationRecord.transaction do
          context.connection.reload.logo_attachment.update_columns(created_at: 1.day.ago)
          logo_copier(context).verify_retirement!(family: context.family, receipt: receipt)
        end
      end
      assert_equal receipt, logo_copier(context).verify_retirement!(family: context.family, receipt: receipt)
    end
  end

  test "native retirement API does not reopen pre-cutover retained copying" do
    with_native_logo do |context|
      original = logo_snapshot(context)
      assert_raises(Copier::Conflict) { logo_copier(context).run_retained(family: context.family) }
      assert_raises(Copier::Conflict) { logo_copier(context).verify_retained_page(family: context.family) }
      assert_equal original, logo_snapshot(context)
    end
  end

  test "read only retirement replay remains available during later native work" do
    with_native_logo do |context|
      receipt = nil
      Fence.with_exclusive(context.item) do
        copier = logo_copier(context)
        receipt = copier.prepare_retirement(family: context.family)
        ApplicationRecord.transaction do
          copier.apply_retirement!(family: context.family, receipt: receipt)
          delete_legacy_rows(context)
        end
      end
      pending = context.connection.syncs.create!(status: "pending")
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never
      archive = retained_bytes(context)

      assert_equal receipt, logo_copier(context).verify_retirement!(family: context.family, receipt: receipt)
      assert pending.reload.pending?
      assert_equal archive, retained_bytes(context)
    end
  end

  private
    def with_native_logo(**options)
      family = families(:dylan_family)
      previous = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
      with_retained_logo(**options) do |context|
        finish_retained_logo(context)
        prepared = nil
        150.times do
          prepared = Provider::AccountData::MigrationPreparation.new(provider_key: "up", legacy_item_id: context.item.id,
            family: context.family, page_size: 1).run
          break if prepared.awaiting_acceptance?
        end
        assert prepared.awaiting_acceptance?
        result = Provider::AccountData::MigrationCutover.new(provider_key: "up", legacy_item_id: context.item.id,
          family: context.family, page_size: 1).call
        Sync.find(result.sync_id).update!(status: "failed", completed_at: Time.current)
        context.control.reload
        Provider::AccountData::RetiredOwner.prepare!(control: context.control, family: context.family)
        clear_enqueued_jobs
        yield context
      ensure
        Sync.where(syncable_type: "ProviderConnection", syncable_id: context.connection.id).delete_all
      end
    ensure
      Family.where(id: family.id).update_all(previous) if family && previous
      clear_enqueued_jobs
    end

    def delete_legacy_rows(context)
      context.control.reload.update!(state: "retired")
      UpAccount.where(up_item_id: context.item.id).delete_all
      UpItem.where(id: context.item.id).delete_all
    end

    def retained_bytes(context)
      { checkpoint: logo_checkpoint(context).attributes_before_type_cast,
        batches: logo_batches(context).map(&:attributes_before_type_cast) }
    end
end
