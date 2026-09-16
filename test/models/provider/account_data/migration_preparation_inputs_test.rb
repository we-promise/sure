require "test_helper"
require_relative "../../../support/binance_history_bootstrap_test_helper"

class Provider::AccountData::MigrationPreparationInputsTest < ActiveSupport::TestCase
  include BinanceHistoryBootstrapTestHelper
  self.use_transactional_tests = false

  Preparation = Provider::AccountData::MigrationPreparation
  Publisher = Provider::AccountData::Binance::HistoryBootstrap

  setup do
    DebugLogEntry.stubs(:capture)
    travel_to Time.utc(2026, 9, 15)
  end

  teardown do
    travel_back
  end

  test "Binance preparation installs and independently verifies its retained input without changing financial history" do
    with_history_copy do |context|
      before = identity_financial_snapshot(context)
      results = finish(context)
      result = results.last
      receipt = context.mapping.reload.preparation_state.fetch("input")

      assert_includes results.map(&:phase), "install_inputs"
      assert_includes results.map(&:phase), "verify_inputs"
      assert_equal "partial", result.input_integration
      assert_equal 2, result.installed_inputs_count
      assert_equal 2, result.verified_inputs_count
      assert_equal 0, result.unresolved_inputs_count
      assert_equal "installed", receipt.fetch("status")
      assert_equal receipt, context.mapping.preparation_state.fetch("verification_input").fetch("input")
      assert_equal before, identity_financial_snapshot(context)
      assert context.control.reload.quiescing?
      assert context.control.provider_connection.disabled?
      assert_empty context.control.provider_connection.syncs
      refute context.control.preparation_state.fetch("input_contract").fetch("upstream_history_complete")
      assert_equal [ "binance_history/v1", "provider_logo/v1" ], context.control.preparation_state.fetch("input_contract").fetch("handled_inputs")
      assert context.control.preparation_state.fetch("auxiliary_verification").fetch("complete")
    end
  end

  test "a new verification sweep preserves original installation IDs and bytes" do
    with_history_copy do |context|
      finish(context)
      receipt = context.mapping.reload.preparation_state.fetch("input")
      batch = IngestionBatch.find(receipt.fetch("batch_id"))
      checkpoint = ProviderSyncCheckpoint.find(receipt.fetch("checkpoint_id"))
      before = [ batch.attributes, checkpoint.attributes ]
      previous_run = context.control.reload.preparation_state.fetch("verification_run_id")
      travel 1.minute

      restarted = coordinator(context).restart_verification!
      assert_equal "verify_copy", restarted.phase
      assert_equal 0, restarted.verified_inputs_count
      result = finish(context).last

      assert_equal 2, result.verified_inputs_count
      assert_equal receipt, context.mapping.reload.preparation_state.fetch("input")
      assert_equal before, [ batch.reload.attributes, checkpoint.reload.attributes ]
      refute_equal previous_run, context.control.reload.preparation_state.fetch("verification_run_id")
    end
  end

  test "child installation survives a failed parent receipt and resumes with the same IDs" do
    with_history_copy do |context|
      advance_to(context, "install_inputs")
      operation = coordinator(context)
      fail_commit = ->(**_options) { raise "Interrupted parent receipt" }
      operation.stub(:save_progress!, fail_commit) { assert_raises(RuntimeError) { operation.run } }
      assert_nil context.mapping.reload.preparation_state.fetch("input")
      original = context.control.provider_connection.provider_sync_checkpoints.find_by!(stream: Publisher::STREAM)
      original_batch_id = original.ingestion_batch_id

      result = finish(context).last

      receipt = context.mapping.reload.preparation_state.fetch("input")
      assert_equal original.id, receipt.fetch("checkpoint_id")
      assert_equal original_batch_id, receipt.fetch("batch_id")
      assert_equal 2, result.installed_inputs_count
      assert_equal 2, result.verified_inputs_count
    end
  end

  test "lost installed checkpoint cannot be replaced after its parent receipt committed" do
    with_history_copy do |context|
      advance_to(context, "verify_copy")
      receipt = context.mapping.reload.preparation_state.fetch("input")
      ProviderSyncCheckpoint.find(receipt.fetch("checkpoint_id")).delete
      before = context.mapping.reload.preparation_state.deep_dup

      assert_no_difference "IngestionBatch.count" do
        assert_raises(Preparation::Conflict, Provider::AccountData::MigrationCopier::Conflict) { coordinator(context).run }
      end
      assert_equal before, context.mapping.reload.preparation_state
      assert_not_equal "awaiting_acceptance", context.control.reload.preparation_state.fetch("phase")
    end
  end

  test "unlinked Binance history remains an explicit unresolved disposition without financial ownership" do
    with_history_copy(linked: false) do |context|
      result = finish(context).last

      assert_equal 1, result.unresolved_inputs_count
      assert_equal 1, result.installed_inputs_count
      assert_equal 1, result.verified_inputs_count
      assert_equal "unlinked_retained", context.mapping.reload.preparation_state.fetch("input").fetch("status")
      assert_nil context.external.reload.current_account
      assert_empty context.control.provider_connection.provider_sync_checkpoints.where(stream: Publisher::STREAM)
      assert_empty SourceRecord.where(external_account: context.external)
    end
  end

  test "a linked noncombined topology is retained without inventing a native history seed" do
    with_history_copy(account_type: "spot") do |context|
      result = finish(context).last

      assert_equal 1, result.unresolved_inputs_count
      assert_equal 1, result.installed_inputs_count
      assert_equal "unsupported_topology", context.mapping.reload.preparation_state.fetch("input").fetch("status")
      assert_empty context.control.provider_connection.provider_sync_checkpoints.where(stream: Publisher::STREAM)
      assert context.control.reload.quiescing?
    end
  end

  test "old terminal progress cannot bypass the new input stages" do
    with_history_copy do |context|
      finish(context)
      old = context.control.reload.preparation_state.merge("format" => "provider-migration-preparation/v1")
      context.control.update!(preparation_state: old)

      assert_raises(Preparation::Conflict) { coordinator(context).run }
      assert_equal old, context.control.reload.preparation_state
    end
  end

  test "final input verification rechecks source policy and cannot retain a stale success" do
    with_history_copy do |context|
      advance_to(context, "verify_inputs")
      coordinator(context).run # Complete the independent no-logo verification first.
      policy = Account::SourcePolicy.active.find_by!(account: context.account, resource: "activities")
      policy.update!(active: false)
      before = context.mapping.reload.preparation_state.deep_dup

      assert_raises(Publisher::Conflict) { coordinator(context).run }
      assert_equal before, context.mapping.reload.preparation_state
      assert_equal 1, context.control.reload.preparation_state.fetch("verified_inputs_count")
    end
  end

  private
    def coordinator(context)
      Preparation.new(provider_key: "binance", legacy_item_id: context.item.id, family: context.family, page_size: 1)
    end

    def finish(context)
      results = []
      100.times do
        results << coordinator(context).run
        return results if results.last.awaiting_acceptance?
      end
      flunk "Migration input preparation did not finish"
    end

    def advance_to(context, phase)
      100.times do
        result = coordinator(context).run
        return result if result.phase == phase
        flunk "Preparation skipped expected input phase" if result.awaiting_acceptance?
      end
      flunk "Preparation did not reach input phase"
    end
end
