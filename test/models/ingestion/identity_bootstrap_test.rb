require "test_helper"
require_relative "../../support/identity_bootstrap_test_helper"

class Ingestion::IdentityBootstrapTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Publisher = Ingestion::IdentityBootstrap
  Evidence = Ingestion::LegacyIdentityEvidence
  Resolver = Ingestion::MappedEntryResolver

  test "capture publishes exact UUID evidence without issuing financial writes or enabling native sync" do
    with_identity_source do |context|
      entry = identity_entry(context, external_id: "up_booked", user_modified: true, import_locked: true, excluded: true,
        locked_attributes: { "name" => true }, extra: { "up" => { "pending" => false }, "private" => "private-financial-memo",
          "auto_claimed_pending_ids" => [ "up_pending-old" ] })
      before = identity_financial_snapshot(context)
      link_before = context.link.reload.attributes
      copy_before = context.control.reload.high_water_mark
      result, queries = nil, nil

      assert_no_difference [ "Entry.count", "Transaction.count", "Trade.count", "Category.count", "ProviderMerchant.count", "Sync.count" ] do
        queries = capture_sql_queries { result = publisher(context).run }
      end

      assert_no_financial_sql(queries)
      assert_equal before, identity_financial_snapshot(context)
      assert_equal link_before, context.link.reload.attributes
      assert_equal copy_before, context.control.reload.high_water_mark
      batch = IngestionBatch.find(result.batch_id)
      assert batch.applied?
      assert_nil batch.sync_id
      assert_equal "migration", batch.origin_kind
      assert_equal [ entry.id ], batch.payload.fetch("plan").fetch("rows").map { |row| row.fetch("entry_id") }
      assert_equal Evidence::FORMAT, Evidence.validate_batch!(batch).fetch("format")
      assert_provider_column_encrypted(batch, :payload, "private-financial-memo")
      observations = observations(context).order(:external_id)
      assert_equal %w[up_booked up_pending-old], observations.pluck(:external_id)
      assert_equal [ entry.id ], observations.map { |observation| observation.entry_source.entry_identity }.uniq
      assert_equal %w[current retired_alias], observations.map { |observation| observation.entry_source.bootstrap_identity_role }
      assert_equal [ "Transaction" ], observations.map { |observation| observation.entry_source.bootstrap_entryable_type }.uniq
      assert context.control.reload.quiescing?
      assert context.external.provider_connection.reload.disabled?
      assert_empty context.external.provider_connection.syncs
    end
  end

  test "Plaid EU adopts plaid_id-only UUIDs and archive-only retired aliases through the same publisher" do
    with_identity_source(provider_key: "plaid", plaid_transactions: [ { transaction_id: "booked", pending: false, pending_transaction_id: "pending-archive" } ]) do |context|
      entry = identity_entry(context, external_id: nil, source: nil, plaid_id: "booked", user_modified: true,
        extra: { "plaid" => { "pending" => false } })
      before = identity_financial_snapshot(context)

      result = publisher(context).run

      assert_equal before, identity_financial_snapshot(context)
      assert_nil entry.reload.external_id
      assert_nil entry.source
      assert_equal "booked", entry.plaid_id
      batch = IngestionBatch.find(result.batch_id)
      assert_equal "plaid", batch.payload.fetch("plan").fetch("source")
      assert_equal "eu", batch.payload.fetch("plan").fetch("region")
      current = observations(context).find_by!(external_id: "booked")
      retired = observations(context).find_by!(external_id: "pending-archive")
      resolver = Resolver.new(external_account: context.external, account: context.account, definition: Provider::AccountData::Plaid.definition)
      assert_equal entry.id, resolver.resolve(source_record: current, kind: "transaction", external_id: "booked", entryable_type: "Transaction").entry_identity
      resolution = resolver.resolve(source_record: retired, kind: "transaction", external_id: "pending-archive", entryable_type: "Transaction")
      assert resolution.retired_alias?
      assert_nil resolution.entry
      assert_equal entry.id, resolution.entry_identity
      assert_nil entry.transaction.extra["auto_claimed_pending_ids"]
    end
  end

  test "each capture page commits a durable checkpoint that a fresh publisher resumes" do
    with_identity_source do |context|
      entries = 3.times.map { |index| identity_entry(context, external_id: "up_page-#{index}", id: numbered_uuid(index + 1)) }
      before = identity_financial_snapshot(context)
      checkpoint_ids = []
      3.times do |index|
        result = publisher(context, page_size: 1).run
        checkpoint_ids << result.checkpoint_id
        assert_equal index + 1, observations(context).count
        assert_equal index + 1, batches(context).count
        assert_equal entries.first(index + 1).map(&:id), EntrySource.where(bootstrap_external_account: context.external).order(:entry_identity).pluck(:entry_identity)
      end

      assert_equal 1, checkpoint_ids.uniq.size
      checkpoint = ProviderSyncCheckpoint.find(checkpoint_ids.first)
      assert_equal Evidence::STREAM, checkpoint.stream
      assert_equal "account:#{context.external.id}", checkpoint.scope_key
      assert_provider_column_encrypted(checkpoint, :state, '"phase"')
      assert_equal before, identity_financial_snapshot(context)
      result = finish_verification(context, page_size: 1)
      assert result.verified?
      assert_equal 3, observations(context).count
      assert_equal 3, batches(context).count
    end
  end

  test "retry after verified completion reuses immutable evidence and never adds financial or source rows" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_once")
      finish_capture(context)
      first = finish_verification(context)
      before = batches(context).order(:id).map(&:attributes)
      result = nil

      assert_no_difference [ "SourceRecord.count", "EntrySource.count", "IngestionBatch.count", "ProviderSyncCheckpoint.count", "Entry.count" ] do
        result = publisher(context).run
      end

      assert result.verified?
      assert result.replayed
      assert_equal first.checkpoint_id, result.checkpoint_id
      assert_equal before, batches(context).order(:id).map(&:attributes)
    end
  end

  test "publication failure rolls back captured evidence observations mappings and checkpoint together" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_atomic")
      before = identity_financial_snapshot(context)
      EntrySource.any_instance.expects(:save!).raises(IOError, "interrupted identity publication")

      assert_no_difference [ "IngestionBatch.count", "SourceRecord.count", "EntrySource.count", "ProviderSyncCheckpoint.count" ] do
        assert_raises(IOError) { publisher(context).run }
      end

      assert_equal before, identity_financial_snapshot(context)
      assert context.control.reload.quiescing?
      assert context.external.provider_connection.reload.disabled?
      EntrySource.any_instance.unstub(:save!)
      result = publisher(context).run
      assert IngestionBatch.find(result.batch_id).applied?
      assert_equal 1, observations(context).count
    end
  end

  test "a changed account link revision cannot resume an earlier committed capture checkpoint" do
    with_identity_source do |context|
      2.times { |index| identity_entry(context, external_id: "up_revision-#{index}", id: numbered_uuid(index + 1)) }
      first = publisher(context, page_size: 1).run
      checkpoint = ProviderSyncCheckpoint.find(first.checkpoint_id)
      before = checkpoint.attributes
      context.link.reload.touch

      assert_no_difference [ "IngestionBatch.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Publisher::Conflict) { publisher(context, page_size: 1).run }
      end

      assert_equal before, checkpoint.reload.attributes
      assert_equal 1, observations(context).count
    end
  end

  test "a blocked identity cannot advance capture or publish the other rows on its page" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_valid")
      blocked = identity_entry(context, external_id: nil)
      before = identity_financial_snapshot(context)

      assert_no_difference [ "IngestionBatch.count", "SourceRecord.count", "EntrySource.count", "ProviderSyncCheckpoint.count" ] do
        assert_raises(Publisher::Conflict) { publisher(context).run }
      end

      assert_nil blocked.reload.external_id
      assert_equal before, identity_financial_snapshot(context)
    end
  end

  test "verified ownership is family scoped and a shadow copy is not a quiescence permit" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_private")
      assert_no_difference [ "IngestionBatch.count", "SourceRecord.count", "EntrySource.count", "ProviderSyncCheckpoint.count" ] do
        assert_raises(Publisher::Conflict) { Publisher.new(mapping: context.mapping, family: families(:empty)).run }
      end
    end
    with_identity_source(quiesced: false) do |context|
      identity_entry(context, external_id: "up_shadow")
      assert_no_difference [ "IngestionBatch.count", "SourceRecord.count", "EntrySource.count", "ProviderSyncCheckpoint.count" ] do
        assert_raises(Publisher::Conflict) { publisher(context).run }
      end
      assert context.control.reload.shadow?
    end
  end

  test "verification compares identities while retaining immutable original financial snapshots after user edits" do
    with_identity_source do |context|
      entry = identity_entry(context, external_id: "up_editable")
      finish_capture(context)
      evidence = batches(context).sole
      original_payload = evidence.payload
      entry.update!(amount: BigDecimal("27.8912"), name: "My corrected description", user_modified: true)
      edited = identity_financial_snapshot(context)
      result, queries = nil, nil

      queries = capture_sql_queries { result = finish_verification(context) }

      assert result.verified?
      assert_no_financial_sql(queries)
      assert_equal edited, identity_financial_snapshot(context)
      assert_equal original_payload, evidence.reload.payload
      assert_equal entry.id, observations(context).sole.entry_source.entry_identity
    end
  end

  test "verification never recreates an observation or proof missing after capture" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_missing-proof")
      finish_capture(context)
      checkpoint = bootstrap_checkpoint(context)
      before = checkpoint.attributes
      observation = observations(context).sole
      observation.entry_source.delete
      observation.delete

      assert_no_difference [ "IngestionBatch.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Publisher::Conflict) { publisher(context).run }
      end

      assert_equal before, checkpoint.reload.attributes
      assert_empty observations(context)
    end
  end

  test "an orphan captured observation is rejected instead of silently manufacturing its posting proof" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_orphan")
      finish_capture(context)
      observations(context).sole.entry_source.delete
      before = bootstrap_checkpoint(context).attributes

      assert_no_difference [ "IngestionBatch.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Publisher::Conflict) { publisher(context).run }
      end

      assert_equal before, bootstrap_checkpoint(context).attributes
      assert_equal 1, observations(context).count
    end
  end

  test "a lower UUID inserted behind the verification cursor prevents a false complete inventory" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_first", id: numbered_uuid(40))
      identity_entry(context, external_id: "up_last", id: numbered_uuid(80))
      finish_capture(context, page_size: 1)
      first_verification = publisher(context, page_size: 1).run
      assert_not first_verification.verified?
      checkpoint = bootstrap_checkpoint(context)
      before = checkpoint.attributes
      inserted = identity_entry(context, external_id: "up_inserted-behind", id: numbered_uuid(20))

      assert_no_difference [ "IngestionBatch.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Publisher::Conflict) { publisher(context, page_size: 1).run }
      end

      assert_equal before, checkpoint.reload.attributes
      assert_not observations(context).exists?(external_id: inserted.external_id)
      assert context.control.reload.quiescing?
      assert context.external.provider_connection.reload.disabled?
    end
  end

  test "restart verification preserves captured evidence and cannot turn missing identities into capture" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_captured", id: numbered_uuid(40))
      finish_capture(context, page_size: 1)
      finish_verification(context, page_size: 1)
      original = batches(context).order(:id).map(&:attributes)
      inserted = identity_entry(context, external_id: "up_requires-new-review", id: numbered_uuid(20))

      assert_no_difference [ "IngestionBatch.count", "SourceRecord.count", "EntrySource.count" ] do
        publisher(context, page_size: 1).restart_verification!
        assert_raises(Publisher::Conflict) { publisher(context, page_size: 1).run }
      end

      assert_equal original, batches(context).order(:id).map(&:attributes)
      assert_not observations(context).exists?(external_id: inserted.external_id)
    end
  end

  test "a pending flag changed behind the verification cursor prevents terminal completion" do
    assert_terminal_identity_drift do |_context, entry|
      entry.transaction.update!(extra: { "up" => { "pending" => true } })
    end
  end

  test "a retired alias added behind the verification cursor prevents terminal completion" do
    assert_terminal_identity_drift do |_context, entry|
      entry.transaction.update!(extra: { "up" => { "pending" => false }, "auto_claimed_pending_ids" => [ "up_new-alias" ] })
    end
  end

  test "a retired alias removed behind the verification cursor cannot erase its retained proof" do
    assert_terminal_identity_drift(extra: { "up" => { "pending" => false }, "auto_claimed_pending_ids" => [ "up_old-alias" ] }) do |_context, entry|
      entry.transaction.update!(extra: { "up" => { "pending" => false }, "auto_claimed_pending_ids" => [] })
    end
  end

  test "a verified row moved out of the source candidate scope is caught by the reverse terminal check" do
    assert_terminal_identity_drift do |_context, entry|
      entry.update!(source: "manual", external_id: "manual-reclassified")
    end
  end

  test "a financial retype behind the verification cursor cannot reuse the retained Transaction proof" do
    original_transaction_id = nil
    assert_terminal_identity_drift do |_context, entry|
      original_transaction_id = entry.entryable_id
      trade = Trade.create!(security: securities(:aapl), qty: BigDecimal("1"), price: BigDecimal("12.3456"), currency: "USD")
      entry.update!(entryable: trade)
    end
  ensure
    # The deliberately replaced polymorphic row no longer belongs to the test
    # account's dependent cleanup. Do not invoke stale inverse associations.
    Transaction.where(id: original_transaction_id).delete_all if original_transaction_id
  end

  test "ordinary financial and category edits behind the cursor remain outside terminal identity comparison" do
    with_identity_source do |context|
      entry = identity_entry(context, external_id: "up_first", id: numbered_uuid(40), extra: { "up" => { "pending" => false } })
      identity_entry(context, external_id: "up_last", id: numbered_uuid(80))
      finish_capture(context, page_size: 1)
      assert_not publisher(context, page_size: 1).run.verified?
      original_batches = batches(context).order(:id).map(&:attributes)
      entry.update!(name: "My later description", amount: BigDecimal("27.8912"), user_modified: true)
      entry.transaction.update!(category: categories(:food_and_drink), extra: { "up" => { "pending" => false }, "private_note" => "My later note" })
      edited = identity_financial_snapshot(context)
      result = nil

      queries = capture_sql_queries { result = publisher(context, page_size: 1).run }

      assert result.verified?
      assert_no_financial_sql(queries)
      assert_equal edited, identity_financial_snapshot(context)
      assert_equal original_batches, batches(context).order(:id).map(&:attributes)
    end
  end

  test "explicit capture restart recovers a late lower UUID while retaining every original batch and mapping" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_first", id: numbered_uuid(40))
      identity_entry(context, external_id: "up_last", id: numbered_uuid(80))
      finish_capture(context, page_size: 1)
      publisher(context, page_size: 1).run
      original_batches = batches(context).order(:id).to_h { |batch| [ batch.id, batch.attributes ] }
      original_mappings = EntrySource.where(bootstrap_external_account: context.external).order(:id).to_h { |mapping| [ mapping.id, mapping.attributes ] }
      late = identity_entry(context, external_id: "up_late", id: numbered_uuid(20))
      assert_raises(Publisher::Conflict) { publisher(context, page_size: 1).run }
      before = identity_financial_snapshot(context)

      restarted = publisher(context, page_size: 1).restart_capture!
      assert_equal "capture", restarted.phase
      assert_equal 2, restarted.captured_entries
      assert_equal 0, restarted.verified_entries
      finish_capture(context, page_size: 1)
      verified = finish_verification(context, page_size: 1)

      assert verified.verified?
      assert_equal 3, verified.captured_entries
      assert_equal 3, verified.verified_entries
      assert_equal 3, batches(context).count
      assert_equal 3, observations(context).count
      assert_equal late.id, observations(context).find_by!(external_id: "up_late").entry_source.entry_identity
      original_batches.each { |id, attributes| assert_equal attributes, IngestionBatch.find(id).attributes }
      original_mappings.each { |id, attributes| assert_equal attributes, EntrySource.find(id).attributes }
      assert_equal before, identity_financial_snapshot(context)
      assert context.control.reload.quiescing?
      assert context.external.provider_connection.reload.disabled?
    end
  end

  test "lost progress cannot silently start another capture over retained immutable evidence" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_retained")
      finish_capture(context)
      bootstrap_checkpoint(context).delete
      original_batches = batches(context).order(:id).map(&:attributes)

      assert_no_difference [ "IngestionBatch.count", "SourceRecord.count", "EntrySource.count", "ProviderSyncCheckpoint.count" ] do
        assert_raises(Publisher::Conflict) { publisher(context).run }
      end

      assert_equal original_batches, batches(context).order(:id).map(&:attributes)
    end
  end

  test "an empty financial inventory can verify without creating fictional observations or provider coverage" do
    with_identity_source do |context|
      result = nil
      assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count", "Sync.count" ] do
        finish_capture(context)
        result = finish_verification(context)
      end

      assert result.verified?
      assert_equal 0, result.captured_entries
      assert_equal 0, result.verified_entries
      assert context.external.provider_connection.reload.disabled?
      assert_empty context.external.provider_connection.provider_sync_checkpoints.where.not(stream: [ "legacy_state", Evidence::STREAM ])
    end
  end

  private
    def assert_terminal_identity_drift(extra: { "up" => { "pending" => false } })
      with_identity_source do |context|
        entry = identity_entry(context, external_id: "up_first", id: numbered_uuid(40), extra: extra)
        identity_entry(context, external_id: "up_last", id: numbered_uuid(80))
        finish_capture(context, page_size: 1)
        result = publisher(context, page_size: 1).run
        assert_not result.verified?
        assert_equal 1, result.verified_entries
        checkpoint = bootstrap_checkpoint(context)
        progress = checkpoint.attributes
        original_batches = batches(context).order(:id).map(&:attributes)
        original_mappings = EntrySource.where(bootstrap_external_account: context.external).order(:id).map(&:attributes)
        yield context, entry
        edited = identity_financial_snapshot(context)

        assert_no_difference [ "IngestionBatch.count", "SourceRecord.count", "EntrySource.count" ] do
          queries = capture_sql_queries do
            assert_raises(Publisher::Conflict) { publisher(context, page_size: 1).run }
          end
          assert_no_financial_sql(queries)
        end

        assert_equal progress, checkpoint.reload.attributes
        assert_equal original_batches, batches(context).order(:id).map(&:attributes)
        assert_equal original_mappings, EntrySource.where(bootstrap_external_account: context.external).order(:id).map(&:attributes)
        assert_equal edited, identity_financial_snapshot(context)
        assert context.control.reload.quiescing?
        assert context.external.provider_connection.reload.disabled?
      end
    end

    def publisher(context, page_size: 100)
      Publisher.new(mapping: context.mapping, family: context.family, page_size: page_size)
    end

    def batches(context)
      context.external.provider_connection.ingestion_batches.where(stream: Evidence::STREAM, external_account: context.external)
    end

    def observations(context)
      SourceRecord.where(external_account: context.external)
    end

    def bootstrap_checkpoint(context)
      context.external.provider_connection.provider_sync_checkpoints.find_by!(stream: Evidence::STREAM, scope_key: "account:#{context.external.id}")
    end

    def finish_capture(context, page_size: 100)
      15.times do
        result = publisher(context, page_size: page_size).run
        return result if %w[verify verified].include?(result.phase.to_s)
      end
      flunk "Identity capture did not finish within bounded calls"
    end

    def finish_verification(context, page_size: 100)
      15.times do
        result = publisher(context, page_size: page_size).run
        return result if result.verified?
      end
      flunk "Identity verification did not finish within bounded calls"
    end

    def numbered_uuid(number)
      format("00000000-0000-4000-8000-%012x", number)
    end
end
