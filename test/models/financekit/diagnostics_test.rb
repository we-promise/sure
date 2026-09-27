require "test_helper"
require_relative "../../support/financekit_test_helper"

class Financekit::DiagnosticsTest < ActiveSupport::TestCase
  include FinancekitTestHelper

  setup { financekit_setup }

  test "accepted and imported batches can be traced without recording financial payloads" do
    batch, = accept_batch
    accepted = log_for("upload_accepted")
    assert_equal @family, accepted.family
    assert_equal @user, accepted.user
    assert_equal batch.batch_id, accepted.metadata["batch_id"]
    assert_equal @item.id, accepted.metadata["connection_id"]
    assert_equal 3, accepted.metadata["event_count"]

    applied = Financekit::Processor.new(@item).apply_next!
    assert applied
    imported = log_for("capture_imported")
    assert_equal batch.batch_id, imported.metadata["batch_id"]
    assert_equal 1, imported.metadata.dig("counts", "upserted")

    # Downstream work is the drain's, not the processor's, so it completes the
    # whole applied capture in one pass.
    Financekit::Downstream.new(@item, FinancekitBatch.where(id: applied.map(&:id))).perform!
    completed = log_for("downstream_completed")
    assert_equal applied.size, completed.metadata["batches"]
    assert_equal batch.batch_id, completed.metadata["batch_id"]
    assert_private_fields_absent
  end

  test "rejected uploads record typed errors even when their transaction rolls back" do
    payload = financekit_payload.merge("generation" => @item.generation + 1)
    assert_raises(Financekit::Error) { accept_batch(payload) }

    rejected = log_for("upload_rejected")
    assert_equal "generation_conflict", rejected.metadata["error_code"]
    assert_equal "warn", rejected.level
    assert_private_fields_absent

    travel 1.second
    assert_raises(Financekit::Error) { FinancekitBatch.accept!(@item, '{"secret":') }
    assert_equal "invalid_json", log_for("upload_rejected").metadata["error_code"]
    refute_includes log_for("upload_rejected").metadata.to_json, "secret"
  end

  test "retry diagnostics include attempts deadline and error class without exception messages" do
    batch, = accept_batch
    Account::ProviderImportAdapter.any_instance.stubs(:update_balance).raises(RuntimeError, "private-financial-details")
    Rails.error.stubs(:report)

    assert_not Financekit::Processor.new(@item).apply_next!
    retry_log = log_for("import_retry")
    assert_equal "warn", retry_log.level
    assert_equal 1, retry_log.metadata["attempts"]
    assert_equal batch.reload.retry_at.iso8601, retry_log.metadata["retry_at"]
    assert_equal "RuntimeError", retry_log.metadata["error_class"]
    refute_includes retry_log.metadata.to_json, "private-financial-details"
  end

  test "permanent failures and failures before selecting a batch are visible" do
    batch, = accept_batch
    batch.update!(predecessor_digest: "0" * 64)
    assert_not Financekit::Processor.new(@item).apply_next!
    failed = log_for("import_failed")
    assert_equal "error", failed.level
    assert_equal "repair_required", failed.metadata["connection_status"]
    assert_equal "predecessor_conflict", failed.metadata["error_code"]

    assert_not Financekit::Processor.new(@item).apply_next!
    assert_equal "repair_required", log_for("import_blocked").metadata["error_code"]
  end

  test "downstream failures include the affected account provider" do
    batch, = accept_batch
    Account.any_instance.stubs(:sync_later).raises(RuntimeError, "private-financial-details")

    Financekit::Downstream.new(@item, FinancekitBatch.where(id: batch.id)).perform!

    log = log_for("downstream_failed")
    assert_equal @source.financekit_account_lineage.account_provider, log.account_provider
    assert_equal @source.account, log.account
    assert_equal "RuntimeError", log.metadata["error_class"]
    refute_includes log.metadata.to_json, "private-financial-details"
    assert_nil batch.reload.downstream_completed_at
  end

  private
    def log_for(event)
      DebugLogEntry.where(provider_key: "financekit").where("metadata ->> 'event' = ?", event).order(created_at: :desc, id: :desc).first!
    end

    def assert_private_fields_absent
      logs = DebugLogEntry.where(provider_key: "financekit").pluck(:metadata).to_json
      [ @credential, @item.credential_digest, "Synthetic shop", "SYNTHETIC SHOP", "Test Wallet", "112.66" ].each do |value|
        refute_includes logs, value
      end
    end
end
