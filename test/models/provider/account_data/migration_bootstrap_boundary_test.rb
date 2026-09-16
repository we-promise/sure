require "test_helper"
require_relative "../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::MigrationBootstrapBoundaryTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Copier = Provider::AccountData::MigrationCopier
  Evidence = Ingestion::LegacyIdentityEvidence

  test "missing identity checkpoint cannot reopen legacy ownership or replace the retained copy run" do
    with_identity_source do |context|
      entry = identity_entry(context, external_id: "up_retained", user_modified: true)
      Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family).run
      identity_checkpoints(context).delete_all
      assert EntrySource.exists?(entry_identity: entry.id, bootstrap_external_account: context.external)

      assert_default_copy_paths_reject(context)
    end
  end

  test "an orphan financial identity batch blocks restart even after all observations and progress are lost" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_orphaned-batch")
      Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family).run
      identity_checkpoints(context).delete_all
      observations = SourceRecord.where(external_account: context.external)
      EntrySource.where(source_record_id: observations.select(:id)).delete_all
      observations.delete_all
      assert_empty EntrySource.where(bootstrap_external_account: context.external)
      assert context.external.provider_connection.ingestion_batches.exists?(origin_kind: "migration", stream: Evidence::STREAM)

      assert_default_copy_paths_reject(context)
    end
  end

  test "residual bootstrap association blocks restart independently of batch stream and checkpoint discovery" do
    with_identity_source do |context|
      entry = identity_entry(context, external_id: "up_untrusted-association")
      archive = context.external.provider_connection.ingestion_batches.find_by!(stream: "legacy_snapshot", external_account: context.external)
      # Simulate inconsistent restored data while preserving real ownership FKs.
      # This is deliberately not valid signed migration evidence. The copier
      # must stop even if its batch-stream query cannot discover the association.
      observation = SourceRecord.new(family: context.family, account: context.account, external_account: context.external,
        ingestion_batch: archive, kind: "transaction", external_id: entry.external_id, input_external_id: entry.external_id, input_occurrence: 0)
      observation.save!(validate: false)
      association = EntrySource.new(source_record: observation, entry: entry, entry_identity: entry.id, family: context.family,
        account: context.account, role: "posting", match_method: "legacy_external_id", bootstrap_batch: archive,
        bootstrap_external_account: context.external, bootstrap_identity_role: "current", bootstrap_entryable_type: "Transaction",
        bootstrap_identity_state: Ingestion::FinancialIdentityState.from_snapshot("entry" => entry.attributes, "entryable" => entry.transaction.attributes))
      association.save!(validate: false)
      assert_not association.valid?
      assert_empty identity_checkpoints(context)
      assert_not context.external.provider_connection.ingestion_batches.exists?(origin_kind: "migration", stream: Evidence::STREAM)

      assert_default_copy_paths_reject(context)
    end
  end

  test "retained identity evidence on another connection does not prevent this connection returning to legacy" do
    with_identity_source do |retained|
      identity_entry(retained, external_id: "up_other-connection")
      Ingestion::IdentityBootstrap.new(mapping: retained.mapping, family: retained.family).run
      identity_checkpoints(retained).delete_all
      retained_before = retained.control.reload.attributes

      with_identity_source do |untouched|
        result = untouched.copier.resume_legacy!
        assert result.legacy?
        assert result.provider_connection.disabled?
        assert_equal retained_before, retained.control.reload.attributes
        assert retained.control.quiescing?
      end
    end
  end

  private
    def identity_checkpoints(context)
      context.external.provider_connection.provider_sync_checkpoints.where(stream: Evidence::STREAM)
    end

    def retained_state(context)
      { control: context.control.reload.attributes, connection: context.external.provider_connection.reload.attributes,
        mappings: context.control.provider_migration_mappings.order(:id).map(&:attributes),
        batches: context.external.provider_connection.ingestion_batches.order(:id).map(&:attributes),
        checkpoints: context.external.provider_connection.provider_sync_checkpoints.order(:id).map(&:attributes),
        observations: SourceRecord.where(external_account: context.external).order(:id).map(&:attributes),
        entry_sources: EntrySource.where(bootstrap_external_account: context.external).order(:id).map(&:attributes),
        financial: identity_financial_snapshot(context), link: context.link.reload.attributes }
    end

    def assert_default_copy_paths_reject(context)
      original = retained_state(context)
      [ -> { context.copier.run_quiesced }, -> { context.copier.run_quiesced(restart: true) }, -> { context.copier.resume_legacy! } ].each do |operation|
        assert_no_difference [ "IngestionBatch.count", "SourceRecord.count", "EntrySource.count", "ProviderSyncCheckpoint.count" ] do
          assert_raises(Copier::Conflict, &operation)
        end
        assert_equal original, retained_state(context)
        assert context.control.quiescing?
        assert context.external.provider_connection.disabled?
      end
    end
end
