require "test_helper"
require_relative "../../../support/retained_account_index_test_helper"

class Provider::AccountData::RetainedAccountIndexTest < ActiveSupport::TestCase
  include RetainedAccountIndexTestHelper
  self.use_transactional_tests = false

  Index = Provider::AccountData::RetainedAccountIndex
  Copier = Provider::AccountData::MigrationCopier
  Receipt = ProviderMigrationAccountBinding

  setup do
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  test "real copies index every encrypted account chunk without changing financial records or activating targets" do
    with_retained_account_copy do |context|
      receipt = retained_receipt(context)
      chunks = retained_chunks(context)
      original = receipt.attributes
      financial = context.account.reload.attributes
      assert_operator chunks.count, :>, 1
      assert receipt.linked?
      assert_equal context.family.id, receipt.family_id
      assert_equal context.account.id, receipt.financial_account_id
      assert_equal context.link.id, receipt.account_provider_id
      assert_equal chunks.first.id, receipt.first_batch_id
      assert_equal chunks.count, receipt.chunk_count
      assert_empty Index.unindexed_chunks(family_id: context.family.id)
      assert_equal [ receipt.id ], Index.for_account(context.account).pluck(:id)
      assert_provider_column_encrypted(chunks.first, :payload, "銀行")

      assert_no_difference "Receipt.count" do
        assert_equal receipt.id, Index.capture!(mapping: context.mapping).id
        assert_equal receipt.id, Index.verify!(mapping: context.mapping).id
      end

      assert_equal original, receipt.reload.attributes
      assert_equal financial, context.account.reload.attributes
      assert context.control.reload.shadow?
      assert context.control.provider_connection.disabled?
      refute_includes receipt.attributes.to_json, "private-retained-token"
    end
  end

  test "explicitly unlinked copies retain an indexed absence of financial ownership" do
    with_retained_account_copy(linked: false) do |context|
      receipt = Index.verify!(mapping: context.mapping)

      assert receipt.unlinked?
      assert_nil receipt.financial_account_id
      assert_nil receipt.account_provider_id
      assert_empty Index.for_account(context.account)
      assert_empty Index.unindexed_chunks(family_id: context.family.id)
      assert_empty context.control.provider_connection.account_providers
    end
  end

  test "superseded shadow versions retain both original financial identities after the live join disappears" do
    with_retained_account_copy do |context|
      first = retained_receipt(context)
      first_checksum = first.source_checksum
      first_archive = context.copier.snapshot_for(context.mapping)
      original_batches = retained_chunks(context).to_h { |batch| [ batch.id, batch.attributes ] }
      other = context.family.accounts.create!(name: "Later owner", currency: "USD", balance: 0, accountable: Depository.new)
      context.link.update!(account: other)
      context.source.update!(current_balance: BigDecimal("456.7891"))
      finish_retained_shadow_copy(context.copier)
      context.mapping.reload
      latest = retained_receipt(context)

      refute_equal first_checksum, latest.source_checksum
      assert_equal context.account.id, Index.verify!(mapping: context.mapping, source_checksum: first_checksum).financial_account_id
      assert_equal other.id, latest.financial_account_id
      assert_equal first_archive, context.copier.snapshot_for(context.mapping, source_checksum: first_checksum)
      assert_equal [ first.id ], Index.for_account(context.account).pluck(:id)
      assert_equal [ latest.id ], Index.for_account(other).pluck(:id)
      original_batches.each { |id, attributes| assert_equal attributes, IngestionBatch.find(id).attributes }

      context.link.delete
      assert_equal first.id, Index.verify!(mapping: context.mapping, source_checksum: first_checksum).id
      assert_equal latest.id, Index.verify!(mapping: context.mapping).id
      assert_empty Index.unindexed_chunks(family_id: context.family.id)
    end
  end

  test "bounded historical backfill recovers old versions without replacing the current mapping or copy progress" do
    with_retained_account_copy do |context|
      original_checksum = context.mapping.source_checksum
      context.source.update!(current_balance: BigDecimal("999.1234"))
      finish_retained_shadow_copy(context.copier)
      context.mapping.reload
      current_checksum = context.mapping.source_checksum
      Receipt.where(provider_migration_mapping_id: context.mapping.id).delete_all
      before = {
        mapping: context.mapping.attributes, control: context.control.reload.attributes,
        chunks: context.control.provider_connection.ingestion_batches.order(:id).map(&:attributes)
      }
      assert_raises(Copier::Conflict) { Index.verify!(mapping: context.mapping, source_checksum: original_checksum) }
      assert Index.unindexed_chunks(family_id: context.family.id).exists?

      first = Index.backfill_page(family_id: context.family.id, limit: 1)
      assert_equal 1, first.processed
      refute first.complete
      assert first.next_cursor.present?
      second = Index.backfill_page(family_id: context.family.id, after_id: first.next_cursor, limit: 1)
      assert_equal 1, second.processed
      assert second.complete
      assert_nil second.next_cursor
      assert_equal [ original_checksum, current_checksum ].sort,
        Receipt.where(provider_migration_mapping_id: context.mapping.id).pluck(:source_checksum).sort
      assert_no_difference "Receipt.count" do
        Index.backfill_page(family_id: context.family.id, limit: 1)
        Index.capture!(mapping: context.mapping, source_checksum: original_checksum)
      end
      assert_empty Index.unindexed_chunks(family_id: context.family.id)
      assert_equal before.fetch(:mapping), context.mapping.reload.attributes
      assert_equal before.fetch(:control), context.control.reload.attributes
      assert_equal before.fetch(:chunks), context.control.provider_connection.ingestion_batches.order(:id).map(&:attributes)
    end
  end

  test "historical account lookups remain family scoped even when the supplied UUID belongs elsewhere" do
    with_retained_account_copy do |context|
      foreign_identity = Account.new(id: context.account.id, family_id: families(:empty).id)
      assert_empty Index.for_account(foreign_identity)
      stale_mapping = ProviderMigrationMapping.find(context.mapping.id)
      stale_mapping.family_id = families(:empty).id
      assert_raises(Copier::Conflict) { Index.verify!(mapping: stale_mapping) }
      assert_equal context.account.id, Index.verify!(mapping: context.mapping).financial_account_id
    end
  end

  test "a missing superseded receipt blocks completeness even when the current archive still verifies" do
    with_retained_account_copy do |context|
      old_receipt = retained_receipt(context)
      context.source.update!(current_balance: 51)
      finish_retained_shadow_copy(context.copier)
      context.mapping.reload
      latest = retained_receipt(context)
      old_receipt.delete

      assert_equal latest.id, Index.verify!(mapping: context.mapping).id
      assert_raises(Copier::Conflict) { Index.assert_complete_for!(context.control) }
      assert_raises(Copier::Conflict) do
        10.times { context.copier.run }
        flunk "A comparison with unindexed historical chunks must not finish"
      end
      assert context.control.reload.failed?
      Index.capture!(mapping: context.mapping, source_checksum: old_receipt.source_checksum)

      assert Index.assert_complete_for!(context.control)
      finish_retained_shadow_copy(context.copier)
      assert context.control.reload.shadow?
    end
  end

  test "a changed encrypted chunk fails checksum verification despite an existing receipt" do
    with_retained_account_copy do |context|
      receipt = retained_receipt(context)
      batch = retained_chunks(context).first
      batch.update_columns(payload: batch.payload.merge("data" => Base64.strict_encode64("private-corruption")))

      error = assert_raises(Copier::Conflict) { Index.verify!(mapping: context.mapping) }
      refute_includes error.message, "private-corruption"
      assert_equal receipt.id, retained_receipt(context).id
      assert_no_difference "Receipt.count" do
        assert_raises(Copier::Conflict) { Index.capture!(mapping: context.mapping) }
      end
    end
  end

  test "unknown or extra chunks are not hidden by a receipt for another exact inventory" do
    with_retained_account_copy do |context|
      chunks = retained_chunks(context).to_a
      root = chunks.first
      receipt = retained_receipt(context)
      foreign_key = root.idempotency_key.sub(receipt.source_checksum, "v1-#{'f' * 64}")
      unknown = IngestionBatch.create!(root.attributes.except("id", "created_at", "updated_at").merge("idempotency_key" => foreign_key))
      extra = IngestionBatch.create!(root.attributes.except("id", "created_at", "updated_at").merge(
        "sequence" => receipt.chunk_count, "idempotency_key" => root.idempotency_key.sub(/:0\z/, ":#{receipt.chunk_count}")))
      detached = IngestionBatch.create!(root.attributes.except("id", "created_at", "updated_at").merge(
        "external_account_id" => nil, "idempotency_key" => "unknown-account-archive:#{SecureRandom.uuid}"))

      assert_equal [ unknown.id, extra.id, detached.id ].sort, Index.unindexed_chunks(family_id: context.family.id).pluck(:id).sort
      assert_raises(Copier::Conflict) { Index.assert_complete_for!(context.control) }
      assert_raises(Copier::Conflict) { Index.verify!(mapping: context.mapping) }
      assert_equal receipt.attributes, retained_receipt(context).attributes
    end
  end

  test "a missing root is visible as unindexed orphan chunks and cannot be treated as an empty archive" do
    with_retained_account_copy do |context|
      chunks = retained_chunks(context).to_a
      retained_receipt(context).delete
      chunks.first.delete

      assert_equal chunks.drop(1).map(&:id).sort, Index.unindexed_chunks(family_id: context.family.id).pluck(:id).sort
      page = Index.backfill_page(family_id: context.family.id)
      assert page.complete
      assert_equal 0, page.processed
      assert_raises(Copier::Conflict) { Index.capture!(mapping: context.mapping) }
      assert Index.unindexed_chunks(family_id: context.family.id).exists?, "Root enumeration completion does not prove archive coverage"
    end
  end

  test "an account chunk with every routing hint erased remains unresolved rather than becoming an item archive" do
    with_retained_account_copy do |context|
      receipt = retained_receipt(context)
      root = retained_chunks(context).first
      root.update_columns(external_account_id: nil, scope_key: "unknown", idempotency_key: "unknown:#{SecureRandom.uuid}")

      assert_includes Index.unindexed_chunks(family_id: context.family.id).pluck(:id), root.id
      assert_raises(Copier::Conflict) { Index.assert_complete_for!(context.control) }
      assert_raises(Copier::Conflict) { Index.backfill_page(family_id: context.family.id) }
      assert_raises(Copier::Conflict) { Index.verify!(mapping: context.mapping) }
      assert_equal receipt.attributes, retained_receipt(context).attributes
    end
  end

  test "authenticated archives with absent or foreign binding identities cannot manufacture receipts" do
    [ :missing, :foreign_family, :wrong_source, :wrong_external, :wrong_financial ].each do |change|
      with_retained_account_copy do |context|
        binding = context.copier.snapshot_for(context.mapping).fetch("account_binding").deep_dup
        case change
        when :missing then binding = nil
        when :foreign_family then binding.fetch("financial_context")["family_id"] = families(:empty).id
        when :wrong_source then binding.fetch("link")["provider_id"] = SecureRandom.uuid
        when :wrong_external then binding.fetch("link")["external_account_id"] = SecureRandom.uuid
        when :wrong_financial then binding.fetch("link")["account_id"] = SecureRandom.uuid
        end
        write_archived_binding(context, binding)
        # It is an authentic, decryptable HMAC archive; only the binding is unacceptable.
        assert_equal binding, context.copier.snapshot_for(context.mapping)["account_binding"]
        assert_no_difference "Receipt.count" do
          assert_raises(Copier::Conflict) { Index.capture!(mapping: context.mapping) }
        end
        assert Index.unindexed_chunks(family_id: context.family.id).exists?
      end
    end
  end

  test "archive count and stored byte limits reject before encrypted payloads are read" do
    with_retained_account_copy do |context|
      chunks = retained_chunks(context)
      overhead_budget = chunks.count * 4096 + 4
      oversized = chunks.first
      # Repeated characters compress before encryption and would not exercise
      # the stored-byte preflight. Keep this input larger after compression too.
      bytes = SecureRandom.random_bytes(overhead_budget + 65_536)
      oversized.update_columns(payload: oversized.payload.merge("data" => Base64.strict_encode64(bytes)))
      stored_bytes = chunks.pluck(Arel.sql("COALESCE(octet_length(payload::text), 0)")).sum
      assert_operator stored_bytes, :>, overhead_budget
      IngestionBatch.any_instance.expects(:payload).never
      with_copier_limit(:RETAINED_ARCHIVE_CHUNKS, 1) do
        assert_raises(Copier::Conflict) { Index.verify!(mapping: context.mapping) }
      end
      with_copier_limit(:RETAINED_ROW_BYTES, 1) do
        assert_raises(Copier::Conflict) { Index.verify!(mapping: context.mapping) }
      end
    end
  end

  test "a failed backfill page keeps already committed receipts and retries without duplicating them" do
    with_retained_account_copy do |context|
      context.source.update!(current_balance: 72)
      finish_retained_shadow_copy(context.copier)
      Receipt.where(provider_migration_mapping_id: context.mapping.id).delete_all
      attempts = 0
      fail_second = lambda do
        attempts += 1
        raise ActiveRecord::StatementInvalid, "test interrupted index insertion" if attempts == 2
      end
      begin
        Receipt.set_callback(:create, :before, fail_second)
        assert_raises(ActiveRecord::StatementInvalid) { Index.backfill_page(family_id: context.family.id, limit: 2) }
      ensure
        Receipt.skip_callback(:create, :before, fail_second)
      end
      committed = Receipt.where(provider_migration_mapping_id: context.mapping.id).sole
      original = committed.attributes

      result = Index.backfill_page(family_id: context.family.id, limit: 2)

      assert result.complete
      assert_equal 2, result.processed
      assert_equal 2, Receipt.where(provider_migration_mapping_id: context.mapping.id).count
      assert_equal original, committed.reload.attributes
      assert_empty Index.unindexed_chunks(family_id: context.family.id)
    end
  end

  test "backfill rejects invalid page and checksum inputs without touching evidence" do
    with_retained_account_copy do |context|
      [ 0, 101, 1.5, false ].each do |limit|
        assert_raises(ArgumentError) { Index.backfill_page(family_id: context.family.id, limit: limit) }
      end
      assert_raises(ArgumentError) { Index.backfill_page(family_id: context.family.id, after_id: "not-a-uuid") }
      [ "invalid", "v1-#{'A' * 64}", [], false ].each do |checksum|
        assert_raises(Copier::Conflict) { Index.capture!(mapping: context.mapping, source_checksum: checksum) }
      end
      assert_equal 1, Receipt.where(family_id: context.family.id).count
    end
  end

  private

    def write_archived_binding(context, binding)
      # Reproduce an old/malformed writer through the actual typed serializer,
      # encryption and HMAC code. Do not forge a successful reverse-index receipt.
      Provider::AccountData::LegacyWriterFence.with_exclusive(context.item) do
        context.control.with_lock do
          projection = context.copier.manifest.extract_account(context.source.reload)
          context.copier.send(:save_mapping!, context.mapping, context.external, projection, account_binding: binding)
          context.copier.send(:capture_snapshot!, context.mapping, projection, account_binding: binding)
        end
      end
    end

    def with_copier_limit(name, value)
      original = Copier.const_get(name)
      Copier.send(:remove_const, name)
      Copier.const_set(name, value)
      yield
    ensure
      Copier.send(:remove_const, name)
      Copier.const_set(name, original)
    end
end
