require "test_helper"
require_relative "../../support/identity_bootstrap_test_helper"

class Ingestion::LegacyIdentitySigningRotationTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Evidence = Ingestion::LegacyIdentityEvidence

  test "retained evidence survives active signing-key rotation and revoked keys invalidate the transaction cache" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_retained-key")
      result = Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family).run
      batch = IngestionBatch.find(result.batch_id)
      original_payload = batch.payload.deep_dup
      original_configuration = Rails.application.config.x.provider_identity_signing.deep_dup
      assert_equal "test-v1", batch.payload.fetch("signature").fetch("key_id")

      ApplicationRecord.transaction do
        Evidence.with_validation_cache do
          first = Evidence.validate_batch!(batch)
          rotated = original_configuration.deep_dup
          rotated[:active_key_id] = "test-v2"
          rotated[:keys]["test-v2"] = Base64.strict_encode64("b" * 32)
          Rails.application.config.x.provider_identity_signing = rotated
          assert_not_same first, Evidence.validate_batch!(batch)
          assert_equal original_payload, batch.payload
          rotated[:keys].delete("test-v1")

          assert_raises(Evidence::InvalidEvidence) { Evidence.validate_batch!(batch) }
          Rails.application.config.x.provider_identity_signing = original_configuration
          assert_equal original_payload, Evidence.validate_batch!(batch)
        end
      end
    end
  end

  test "old unversioned batch proofs require the explicit historical-key policy" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_legacy-key")
      result = Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family).run
      original = IngestionBatch.find(result.batch_id)
      payload = original.payload.except("signature")
      historical_key = "h" * 32
      payload["signature"] = OpenSSL::HMAC.hexdigest("SHA256", historical_key, Provider::AccountData::MigrationValue.dump(payload))
      legacy = context.external.provider_connection.ingestion_batches.create!(
        family: context.family, external_account: context.external, origin_kind: "migration",
        stream: Evidence::STREAM, scope_key: "account:#{context.external.id}", sequence: 1,
        idempotency_key: SecureRandom.uuid, mode: "unknown", complete: false, payload: payload,
        status: "applied", applied_at: Time.current)
      configuration = Rails.application.config.x.provider_identity_signing.deep_dup
      configuration[:keys]["historical"] = Base64.strict_encode64(historical_key)
      Rails.application.config.x.provider_identity_signing = configuration

      assert_raises(Evidence::InvalidEvidence) { Evidence.validate_batch!(legacy) }
      configuration[:legacy_v1_key_id] = "historical"
      assert_equal payload, Evidence.validate_batch!(legacy)
      assert_equal original.payload, Evidence.validate_batch!(original)
      configuration[:legacy_v1_key_id] = "test-v1"
      assert_raises(Evidence::InvalidEvidence) { Evidence.validate_batch!(legacy) }
    end
  end
end
