require "test_helper"
require_relative "../../../support/binance_history_bootstrap_test_helper"

class Provider::AccountData::MigrationPreparationInputAdmissionTest < ActiveSupport::TestCase
  include BinanceHistoryBootstrapTestHelper
  self.use_transactional_tests = false

  Preparation = Provider::AccountData::MigrationPreparation

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "account input installation cannot skip incomplete identity publication" do
    with_history_copy do |context|
      worker = coordinator(context)
      10.times { break if worker.run.phase == "identities" }
      assert_equal "identities", context.control.reload.preparation_state.fetch("phase")
      changed = context.control.reload.preparation_state.merge("phase" => "install_inputs")
      context.control.update!(preparation_state: changed)
      Provider::AccountData::Binance::HistoryBootstrap.any_instance.expects(:install).never

      assert_raises(Preparation::Conflict) { worker.run }
      assert_equal changed, context.control.reload.preparation_state
    end
  end

  test "final account input requires a completed fresh parent identity receipt" do
    with_history_copy do |context|
      advance_to_inputs(context)
      progress = context.mapping.reload.preparation_state.deep_dup
      progress.fetch("verification_identity")["phase"] = "verify"
      context.mapping.update!(preparation_state: progress)
      Provider::AccountData::Binance::HistoryBootstrap.any_instance.expects(:verify!).never

      assert_raises(Preparation::Conflict) { coordinator(context).run }
      assert_equal progress, context.mapping.reload.preparation_state
      assert_equal 1, context.control.reload.preparation_state.fetch("verified_inputs_count")
    end
  end

  test "final account input requires the fresh identity receipt exact verified entry count" do
    with_history_copy do |context|
      advance_to_inputs(context)
      progress = context.mapping.reload.preparation_state.deep_dup
      progress.fetch("verification_identity")["verified_entries"] += 1
      context.mapping.update!(preparation_state: progress)
      Provider::AccountData::Binance::HistoryBootstrap.any_instance.expects(:verify!).never

      assert_raises(Preparation::Conflict) { coordinator(context).run }
      assert_equal progress, context.mapping.reload.preparation_state
      assert_equal 1, context.control.reload.preparation_state.fetch("verified_inputs_count")
    end
  end

  private
    def coordinator(context)
      Preparation.new(provider_key: "binance", legacy_item_id: context.item.id, family: context.family, page_size: 1)
    end

    def advance_to_inputs(context)
      100.times do
        result = coordinator(context).run
        return if result.phase == "verify_inputs" && context.control.reload.preparation_state.dig("auxiliary_verification", "complete")
        flunk "Preparation skipped final input verification" if result.awaiting_acceptance?
      end
      flunk "Preparation did not reach final input verification"
    end
end
