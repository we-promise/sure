require "test_helper"
require_relative "../../../support/retained_logo_test_helper"

class Provider::AccountData::MigrationPreparationLogoTest < ActiveSupport::TestCase
  include RetainedLogoTestHelper
  self.use_transactional_tests = false

  Preparation = Provider::AccountData::MigrationPreparation
  Auxiliary = Provider::AccountData::AuxiliaryCopier

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "non-IBKR preparation transfers the logo before identities and independently reverifies it without financial writes" do
    %w[up plaid].each do |key|
      with_retained_logo(provider_key: key) do |context|
        before = [ context.account.reload.attributes, context.account.entries.map { |entry| [ entry.attributes, entry.entryable.attributes ] } ]
        advance_to(context, "capture_auxiliary")
        assert_empty context.connection.provider_sync_checkpoints.where(stream: Ingestion::IdentityBootstrap::STREAM)
        queries = capture_sql_queries { @result = finish(context).last }

        assert @result.awaiting_acceptance?
        assert_equal "partial", @result.input_integration
        assert_equal 1, @result.installed_inputs_count
        assert_equal 1, @result.verified_inputs_count
        assert_equal 1, @result.verified_identities_count
        assert_equal [ "provider_logo/v1" ], parent(context).fetch("input_contract").fetch("handled_inputs")
        assert_equal "provider_logo/v1", parent(context).fetch("auxiliary_input").fetch("kind")
        assert parent(context).fetch("auxiliary_verification").fetch("complete")
        assert_equal context.bytes, Auxiliary.for(control: context.control).each_archived_chunk.to_a.join.b
        assert_equal before, [ context.account.reload.attributes, context.account.entries.map { |entry| [ entry.attributes, entry.entryable.attributes ] } ]
        assert_no_financial_sql(queries)
        assert context.connection.reload.disabled?
        assert context.control.reload.quiescing?
        assert_empty context.connection.syncs
      end
    end
  end

  test "fresh workers preserve a non-IBKR child chunk committed before its parent receipt" do
    with_retained_logo(bytes: "private-logo" * 30_000) do |context|
      advance_to(context, "capture_auxiliary")
      operation = coordinator(context)
      fail_commit = ->(**_options) { raise IOError, "Interrupted parent receipt" }
      operation.stub(:save_progress!, fail_commit) { assert_raises(IOError) { operation.run } }
      assert_nil parent(context).fetch("auxiliary_input")
      original_id = logo_checkpoint(context).id
      original_chunk = logo_batches(context).sole.attributes

      result = finish(context).last

      assert_equal 1, result.installed_inputs_count
      assert_equal 1, result.verified_inputs_count
      assert_equal original_id, parent(context).fetch("auxiliary_input").fetch("checkpoint_id")
      assert_equal original_chunk, IngestionBatch.find(original_chunk.fetch("id")).attributes
    end
  end

  test "final page retry and restarted sweep retain original child IDs bytes and timestamps" do
    with_retained_logo(bytes: "private-logo" * 30_000) do |context|
      advance_to(context, "verify_inputs")
      coordinator(context).run
      original = logo_snapshot(context)
      old_parent = parent(context).deep_dup
      operation = coordinator(context)
      fail_commit = ->(**_options) { raise IOError, "Interrupted final receipt" }
      operation.stub(:save_progress!, fail_commit) { assert_raises(IOError) { operation.run } }
      assert_equal old_parent, parent(context)
      assert_equal original, logo_snapshot(context)
      finish(context)
      receipt = parent(context).fetch("auxiliary_input")
      old_run = parent(context).fetch("verification_run_id")

      coordinator(context).restart_verification!
      assert_nil parent(context).fetch("auxiliary_verification")
      assert_equal receipt, parent(context).fetch("auxiliary_input")
      assert_equal 1, finish(context).last.verified_inputs_count
      refute_equal old_run, parent(context).fetch("verification_run_id")
      assert_equal original, logo_snapshot(context)
    end
  end

  test "zero-account no-logo connections still retain one input and reject parent loss" do
    with_retained_logo(sources: false, bytes: nil) do |context|
      result = finish(context).last
      assert_equal 0, result.inventory_count
      assert_equal 1, result.installed_inputs_count
      assert_equal 1, result.verified_inputs_count
      assert_empty logo_batches(context)
      checkpoint = logo_checkpoint(context).attributes
      context.control.update!(preparation_state: nil)

      assert_raises(Preparation::Conflict) { coordinator(context).run }
      assert_nil context.control.reload.preparation_state
      assert_equal checkpoint, logo_checkpoint(context).attributes
    end
  end

  test "prior non-IBKR terminal contracts cannot silently acquire the new logo scope" do
    with_retained_logo(bytes: nil) do |context|
      finish(context)
      old = parent(context).deep_dup
      old["input_contract"] = old.fetch("input_contract").merge("integration" => "not_integrated", "handled_inputs" => [])
      context.control.update!(preparation_state: old)
      before = logo_snapshot(context)

      assert_raises(Preparation::Conflict) { coordinator(context).run }
      assert_equal old, parent(context)
      assert_equal before, logo_snapshot(context)
    end
  end

  test "changed final attachment cannot count as verified or replace retained evidence" do
    with_retained_logo do |context|
      advance_to(context, "verify_inputs")
      original = logo_snapshot(context)
      before = parent(context).deep_dup
      context.connection.logo_attachment.update_columns(created_at: 1.day.ago)
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never

      assert_raises(Auxiliary::Conflict) { coordinator(context).run }
      assert_equal before, parent(context)
      assert_equal 0, parent(context).fetch("verified_inputs_count")
      assert_equal original.fetch(:checkpoint), logo_checkpoint(context).attributes
      assert_equal original.fetch(:batches), logo_batches(context).map(&:attributes)
    end
  end

  test "a foreign family cannot start or adopt a retained logo preparation" do
    with_retained_logo do |context|
      assert_raises(Preparation::Conflict) do
        Preparation.new(provider_key: "up", legacy_item_id: context.item.id, family: families(:empty)).run
      end
      assert_nil context.control.reload.preparation_state
      assert_empty logo_batches(context)
    end
  end

  private
    def coordinator(context)
      Preparation.new(provider_key: context.control.provider_key, legacy_item_id: context.item.id, family: context.family, page_size: 1)
    end

    def parent(context)
      context.control.reload.preparation_state
    end

    def finish(context)
      results = []
      100.times do
        results << coordinator(context).run
        return results if results.last.awaiting_acceptance?
      end
      flunk "Logo preparation did not finish"
    end

    def advance_to(context, phase)
      100.times do
        result = coordinator(context).run
        return result if result.phase == phase
        flunk "Logo preparation skipped expected phase" if result.awaiting_acceptance?
      end
      flunk "Logo preparation did not reach expected phase"
    end
end
