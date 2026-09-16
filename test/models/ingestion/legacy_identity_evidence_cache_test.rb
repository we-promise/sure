require "test_helper"
require_relative "../../support/identity_bootstrap_test_helper"

class Ingestion::LegacyIdentityEvidenceCacheTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Evidence = Ingestion::LegacyIdentityEvidence

  test "one transaction reuses immutable proof while preserving each observation identity check" do
    with_evidence_batch do |context, batch|
      ApplicationRecord.transaction do
        Evidence.with_validation_cache do
          first = Evidence.validate_batch!(batch)
          assert_same first, Evidence.validate_batch!(batch)
          assert first.frozen?
          assert batch.payload.frozen?
          assert batch.payload.fetch("plan").fetch("rows").first.frozen?

          observation = SourceRecord.find_by!(external_account: context.external, external_id: "up_cache")
          observation.ingestion_batch = batch
          found = Evidence.for_observation!(source_record: observation)
          assert_equal "up_cache", found.fetch(:identity).fetch("external_id")
          invalid = SourceRecord.new(family_id: observation.family_id, account_id: observation.account_id,
            external_account_id: observation.external_account_id, ingestion_batch: batch, kind: observation.kind,
            external_id: observation.external_id, input_external_id: "another-input", input_occurrence: 0)
          assert_raises(Evidence::InvalidEvidence) { Evidence.for_observation!(source_record: invalid) }
          assert_same first, Evidence.validate_batch!(batch)
        end
      end
    end
  end

  test "replacing an input payload cannot reuse an earlier valid signature" do
    with_evidence_batch do |_context, batch|
      ApplicationRecord.transaction do
        Evidence.with_validation_cache do
          Evidence.validate_batch!(batch)
          assert_raises(FrozenError) { batch.payload.fetch("admission")["account_id"] = SecureRandom.uuid }
          replacement = batch.payload.deep_dup
          replacement.fetch("admission")["account_id"] = SecureRandom.uuid
          batch.payload = replacement

          assert_raises(Evidence::InvalidEvidence) { Evidence.validate_batch!(batch) }
          batch.reload
          assert_equal Evidence::FORMAT, Evidence.validate_batch!(batch).fetch("format")
        end
      end
    end
  end

  test "cache reuse requires the same batch object and captured tuple" do
    with_evidence_batch do |_context, batch|
      ApplicationRecord.transaction do
        Evidence.with_validation_cache do
          first = Evidence.validate_batch!(batch)
          second = Evidence.validate_batch!(IngestionBatch.find(batch.id))
          assert_not_same first, second
          third = Evidence.validate_batch!(batch)
          assert_not_same second, third
          assert_same third, Evidence.validate_batch!(batch)
          batch.family_id = families(:empty).id

          assert_raises(Evidence::InvalidEvidence) { Evidence.validate_batch!(batch) }
        end
      end
    end
  end

  test "cache cannot cross a savepoint transaction or survive its block" do
    with_evidence_batch do |_context, batch|
      first = nil
      ApplicationRecord.transaction do
        Evidence.with_validation_cache do
          first = Evidence.validate_batch!(batch)
          ApplicationRecord.transaction(requires_new: true) do
            assert_not_same first, Evidence.validate_batch!(batch)
          end
          assert_same first, Evidence.validate_batch!(batch)
        end
        assert_not_same first, Evidence.validate_batch!(batch)
      end
      ApplicationRecord.transaction do
        Evidence.with_validation_cache { assert_not_same first, Evidence.validate_batch!(batch) }
      end
    end
  end

  test "failed cached validation still removes the execution scope" do
    with_evidence_batch do |_context, batch|
      first = nil
      ApplicationRecord.transaction do
        assert_raises(IOError) do
          Evidence.with_validation_cache do
            first = Evidence.validate_batch!(batch)
            raise IOError, "interrupted proof consumer"
          end
        end
        assert_not_same first, Evidence.validate_batch!(batch)
      end
    end
  end

  test "cached capture never satisfies applied state and detects persisted status changes" do
    with_evidence_batch do |context, batch|
      captured = context.external.provider_connection.ingestion_batches.create!(
        family: context.family, external_account: context.external, origin_kind: "migration",
        stream: Evidence::STREAM, scope_key: "account:#{context.external.id}", sequence: 1,
        idempotency_key: SecureRandom.uuid, mode: "unknown", complete: false, payload: batch.payload)

      ApplicationRecord.transaction do
        Evidence.with_validation_cache do
          Evidence.validate_batch!(captured, require_applied: false)
          assert_raises(Evidence::InvalidEvidence) { Evidence.validate_batch!(captured) }
          IngestionBatch.where(id: captured.id).update_all(status: "applying")
          assert_raises(Evidence::InvalidEvidence) { Evidence.validate_batch!(captured, require_applied: false) }
          captured.reload
          Evidence.validate_batch!(captured, require_applied: false)
          captured.update!(status: "applied", applied_at: Time.current)
          assert_equal Evidence::FORMAT, Evidence.validate_batch!(captured).fetch("format")
        end
      end
    end
  end

  private
    def with_evidence_batch
      with_identity_source do |context|
        identity_entry(context, external_id: "up_cache")
        result = Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family).run
        yield context, IngestionBatch.find(result.batch_id)
      end
    end
end
