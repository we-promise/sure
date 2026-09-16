require "test_helper"
require_relative "../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::MigrationPreparationIbkrTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Preparation = Provider::AccountData::MigrationPreparation
  Auxiliary = Provider::AccountData::Ibkr::AuxiliaryCopier

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "IBKR captures one connection input before any account identities and finishes without financial writes" do
    with_ibkr_copy(sources: 2) do
      before = financial_snapshot
      advance_to("capture_auxiliary")
      assert_equal 2, parent.fetch("inventory_count")
      assert_empty identity_checkpoints
      assert_empty EntrySource.where(account: @accounts)

      queries = capture_sql_queries do
        while parent.fetch("phase") == "capture_auxiliary"
          assert_empty identity_checkpoints
          coordinator.run
        end
        assert_equal "complete", auxiliary_checkpoint.state.fetch("phase")
        @result = finish.last
      end

      assert_no_financial_sql(queries)
      assert_equal before, financial_snapshot
      assert_equal 2, @result.verified_identities_count
      assert_equal "partial", @result.input_integration
      assert_equal 1, @result.installed_inputs_count
      assert_equal 1, @result.verified_inputs_count
      assert_equal 0, @result.unresolved_inputs_count
      assert_equal [ "ibkr_auxiliary/v1" ], parent.fetch("input_contract").fetch("handled_inputs")
      refute parent.fetch("input_contract").fetch("upstream_history_complete")
      @control.provider_migration_mappings.where(role: "external_account").each do |mapping|
        assert_nil mapping.preparation_state.fetch("input")
        assert_nil mapping.preparation_state.fetch("verification_input")
      end
      assert @control.reload.quiescing?
      assert @connection.reload.disabled?
      assert_empty @connection.syncs
    end
  end

  test "a connection with no source accounts or logo still has one explicit verified auxiliary receipt" do
    with_ibkr_copy(sources: 0, bytes: nil) do
      result = finish.last

      assert_equal 0, result.inventory_count
      assert_equal 0, result.verified_identities_count
      assert_equal 1, result.installed_inputs_count
      assert_equal 1, result.verified_inputs_count
      assert_equal 0, auxiliary_checkpoint.state.fetch("chunks")
      assert_empty auxiliary_batches
      assert_empty identity_checkpoints
      assert_equal 0, parent.fetch("auxiliary_verification").fetch("verified_chunks")
      assert parent.fetch("auxiliary_verification").fetch("complete")
    end
  end

  test "unlinked sources retain the connection logo without acquiring financial ownership" do
    with_ibkr_copy(linked: false) do
      result = finish.last

      assert_equal 1, result.unlinked_count
      assert_equal 0, result.linked_count
      assert_equal 1, result.verified_inputs_count
      assert_empty identity_checkpoints
      assert_empty SourceRecord.where(external_account_id: @connection.external_accounts.select(:id))
      assert_nil @connection.external_accounts.sole.current_account
    end
  end

  test "fresh workers retain the original checkpoint and enumerate every final chunk in order" do
    with_ibkr_copy do
      advance_to("capture_auxiliary")
      receipts = []
      while parent.fetch("phase") == "capture_auxiliary"
        coordinator.run
        receipts << parent.fetch("auxiliary_input")
      end
      assert_operator receipts.size, :>, 2
      assert_equal 1, receipts.map { |receipt| receipt.fetch("checkpoint_id") }.uniq.size
      assert_equal 1, receipts.map { |receipt| receipt.fetch("context") }.uniq.size
      assert_equal receipts.map { |receipt| receipt.fetch("copied_chunks") }.sort, receipts.map { |receipt| receipt.fetch("copied_chunks") }
      assert_equal receipts.map { |receipt| receipt.fetch("verified_chunks") }.sort, receipts.map { |receipt| receipt.fetch("verified_chunks") }
      advance_to("verify_inputs")
      original = auxiliary_snapshot
      counts = []
      while parent.fetch("phase") == "verify_inputs"
        coordinator.run
        counts << parent.fetch("auxiliary_verification").fetch("verified_chunks")
      end

      assert_equal (1..auxiliary_checkpoint.state.fetch("chunks")).to_a, counts
      assert_equal original, auxiliary_snapshot
      assert_equal parent.fetch("verification_run_id"), parent.fetch("auxiliary_verification").fetch("verification_run_id")
    end
  end

  test "a committed child chunk survives parent failure and resumes without replacing its archive" do
    with_ibkr_copy do
      advance_to("capture_auxiliary")
      operation = coordinator
      fail_commit = ->(**_options) { raise IOError, "Interrupted parent receipt" }
      operation.stub(:save_progress!, fail_commit) { assert_raises(IOError) { operation.run } }
      assert_nil parent.fetch("auxiliary_input")
      original_id = auxiliary_checkpoint.id
      captured = auxiliary_batches.sole.attributes

      result = finish.last

      assert_equal 1, result.installed_inputs_count
      assert_equal 1, result.verified_inputs_count
      assert_equal original_id, parent.fetch("auxiliary_input").fetch("checkpoint_id")
      assert_equal captured, IngestionBatch.find(captured.fetch("id")).attributes
    end
  end

  test "final page receipt failure replays the same read without modifying original child evidence" do
    with_ibkr_copy do
      advance_to("verify_inputs")
      coordinator.run
      before = parent.deep_dup
      original = auxiliary_snapshot
      operation = coordinator
      fail_commit = ->(**_options) { raise IOError, "Interrupted final receipt" }
      operation.stub(:save_progress!, fail_commit) { assert_raises(IOError) { operation.run } }
      assert_equal before, parent
      assert_equal original, auxiliary_snapshot

      assert finish.last.awaiting_acceptance?
      assert_equal original, auxiliary_snapshot
    end
  end

  test "new final sweeps reset only parent progress and preserve original child IDs timestamps and bytes" do
    with_ibkr_copy do
      finish
      original = auxiliary_snapshot
      original_receipt = parent.fetch("auxiliary_input")
      previous_run = parent.fetch("verification_run_id")
      original_copy = @control.high_water_mark.deep_dup
      restarted = coordinator.restart_verification!

      assert_equal "verify_copy", restarted.phase
      assert_equal 0, restarted.verified_inputs_count
      assert_nil parent.fetch("auxiliary_verification")
      assert_equal original_receipt, parent.fetch("auxiliary_input")
      assert_equal original, auxiliary_snapshot
      refute_equal previous_run, parent.fetch("verification_run_id")
      assert_equal 1, finish.last.verified_inputs_count
      assert_equal original, auxiliary_snapshot
      assert_equal original_copy, @control.reload.high_water_mark
    end
  end

  test "a final auxiliary cursor cannot be reused in another verification run" do
    with_ibkr_copy do
      advance_to("verify_inputs")
      coordinator.run
      old_page = parent.fetch("auxiliary_verification")
      coordinator.restart_verification!
      advance_to("verify_inputs")
      changed = parent.merge("auxiliary_verification" => old_page)
      @control.update!(preparation_state: changed)
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never

      assert_raises(Preparation::Conflict) { coordinator.run }
      assert_equal changed, parent
    end
  end

  test "regressed child progress is refused before another blob request" do
    with_ibkr_copy do
      advance_to("capture_auxiliary")
      coordinator.run
      before = parent.deep_dup
      checkpoint = auxiliary_checkpoint
      checkpoint.update!(state: checkpoint.state.merge("copied_chunks" => 0))
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never

      assert_raises(Preparation::Conflict) { coordinator.run }
      assert_equal before, parent
      assert_equal 1, auxiliary_batches.count
    end
  end

  test "lost child checkpoint cannot be replaced while retained chunks or its parent receipt remain" do
    with_ibkr_copy do
      advance_to("identities")
      original = auxiliary_batches.map(&:attributes)
      original_receipt = parent.fetch("auxiliary_input")
      auxiliary_checkpoint.delete

      assert_raises(Preparation::Conflict, Auxiliary::Conflict, Provider::AccountData::MigrationCopier::Conflict, Ingestion::LegacyIdentityEvidence::InvalidEvidence) { finish }
      assert_equal original_receipt, parent.fetch("auxiliary_input")
      assert_equal original, auxiliary_batches.map(&:attributes)
      refute_equal "awaiting_acceptance", parent.fetch("phase")
    end
  end

  test "lost parent progress on a zero-account connection cannot adopt its completed empty child receipt" do
    with_ibkr_copy(sources: 0, bytes: nil) do
      advance_to("identities")
      original = auxiliary_snapshot
      @control.update!(preparation_state: {})

      assert_raises(Preparation::Conflict) { coordinator.run }
      assert_empty parent
      assert_equal original, auxiliary_snapshot
      assert_empty @control.provider_migration_mappings.where(role: "external_account")
    end
  end

  test "lost parent and checkpoint cannot adopt retained chunks on a zero-account connection" do
    with_ibkr_copy(sources: 0) do
      advance_to("identities")
      original = auxiliary_batches.map(&:attributes)
      auxiliary_checkpoint.delete
      @control.update!(preparation_state: {})

      assert_raises(Preparation::Conflict) { coordinator.run }
      assert_empty parent
      assert_equal original, auxiliary_batches.map(&:attributes)
    end
  end

  test "a changed blob after identities prevents final success without replacing retained evidence" do
    with_ibkr_copy do
      advance_to("verify_inputs")
      before = parent.deep_dup
      original = auxiliary_snapshot
      changed = @bytes.dup
      changed.setbyte(0, changed.getbyte(0) ^ 0xff)
      @blob.service.upload(@blob.key, StringIO.new(changed))

      assert_raises(Auxiliary::Conflict) { coordinator.run }
      assert_equal before, parent
      assert_equal original, auxiliary_snapshot
      assert_equal 0, parent.fetch("verified_inputs_count")
    end
  end

  test "IBKR input verification requires its completed fresh identity inventory" do
    with_ibkr_copy do
      advance_to("verify_inputs")
      changed = parent.merge("verified_identities_count" => 0)
      @control.update!(preparation_state: changed)
      ActiveStorage::Blob.any_instance.expects(:download_chunk).never

      assert_raises(Preparation::Conflict) { coordinator.run }
      assert_equal changed, parent
    end
  end

  test "terminal IBKR progress cannot lose its final page receipt" do
    with_ibkr_copy(bytes: nil) do
      finish
      changed = parent.merge("auxiliary_verification" => nil)
      @control.update!(preparation_state: changed)

      assert_raises(Preparation::Conflict) { coordinator.run }
      assert_equal changed, parent
    end
  end

  test "a logo-only provider cannot install account inputs or claim unfinished auxiliary capture" do
    with_identity_source do |context|
      worker = Preparation.new(provider_key: "up", legacy_item_id: context.item.id, family: context.family, page_size: 1)
      worker.run
      original = context.control.reload.preparation_state.deep_dup
      [ original.merge("phase" => "install_inputs"), original.merge("input_dispositions_count" => 1, "installed_inputs_count" => 1) ].each do |invalid|
        context.control.update!(preparation_state: invalid)
        assert_raises(Preparation::Conflict) { worker.run }
        assert_equal invalid, context.control.reload.preparation_state
      end
    end
  end

  private
    def with_ibkr_copy(sources: 1, linked: true, bytes: ("\x00\xFFprivate-logo".b * 24_000))
      with_provider_encryption do
        @family, @bytes = families(:dylan_family), bytes
        @item = IbkrItem.create!(family: @family, name: "IBKR preparation", query_id: "query", token: "private-token")
        @accounts = [ @family.accounts.create!(name: "Retained account", currency: "USD", balance: 100, accountable: Investment.new) ]
        begin
          if bytes
            @blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: "private-logo.png", content_type: "image/png", identify: false)
            @item.logo.attach(@blob)
          end
          sources.times do |index|
            source = @item.ibkr_accounts.create!(name: "Investment #{index}", ibkr_account_id: "ibkr-preparation-#{index}", currency: "USD", current_balance: 100)
            next unless linked
            account = index.zero? ? @accounts.first : @family.accounts.create!(name: "Retained account #{index}", currency: "USD", balance: 100, accountable: Investment.new)
            @accounts << account unless index.zero?
            AccountProvider.create!(account: account, provider: source)
            account.entries.create!(name: "Retained cash activity", amount: 10, date: Date.current, currency: "USD",
              source: "ibkr", external_id: "ibkr_cash_preparation-#{index}", entryable: Transaction.new)
          end
          main = Provider::AccountData::MigrationCopier.new(provider_key: "ibkr", legacy_item_id: @item.id, batch_size: 1)
          30.times do
            @control = main.run_quiesced.reload
            break if @control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", @control.high_water_mark["phase"]
          @connection = @control.provider_connection
          AccountProvider.where(account: @accounts).find_each do |link|
            Account::SourcePolicy.select!(account: link.account, account_provider: link, resource: "activities")
          end
          clear_enqueued_jobs
          yield
        ensure
          ActiveStorage::Attachment.where(record_type: "ProviderConnection", record_id: @connection.id).delete_all if @connection
          ActiveStorage::Attachment.where(record_type: "IbkrItem", record_id: @item.id).delete_all
          @accounts.drop(1).each do |account|
            Account::SourcePolicy.where(account: account).delete_all
            AccountProvider.where(account: account).delete_all
          end
          cleanup_identity_source(@item, @accounts.first)
          @accounts.drop(1).each(&:destroy!)
          @blob&.purge
          @blob = @connection = nil
          clear_enqueued_jobs
        end
      end
    end

    def coordinator
      Preparation.new(provider_key: "ibkr", legacy_item_id: @item.id, family: @family, page_size: 1)
    end

    def parent
      @control.reload.preparation_state
    end

    def finish
      results = []
      150.times do
        results << coordinator.run
        return results if results.last.awaiting_acceptance?
      end
      flunk "IBKR preparation did not finish"
    end

    def advance_to(phase)
      150.times do
        result = coordinator.run
        return result if result.phase == phase
        flunk "IBKR preparation skipped #{phase}" if result.awaiting_acceptance?
      end
      flunk "IBKR preparation did not reach #{phase}"
    end

    def auxiliary_checkpoint
      @connection.provider_sync_checkpoints.find_by!(stream: Auxiliary::STREAM)
    end

    def auxiliary_batches
      @connection.ingestion_batches.where(stream: Auxiliary::STREAM).order(:sequence)
    end

    def identity_checkpoints
      @connection.provider_sync_checkpoints.where(stream: Ingestion::IdentityBootstrap::STREAM)
    end

    def auxiliary_snapshot
      { checkpoint: auxiliary_checkpoint.attributes, batches: auxiliary_batches.map(&:attributes),
        attachments: ActiveStorage::Attachment.where(record_id: [ @item.id, @connection.id ]).order(:id).map(&:attributes) }
    end

    def financial_snapshot
      @accounts.map { |account| [ account.reload.attributes, account.entries.order(:id).map { |entry| [ entry.attributes, entry.entryable.attributes ] } ] }
    end
end
