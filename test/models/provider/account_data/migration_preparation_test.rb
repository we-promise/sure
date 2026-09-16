require "test_helper"
require "timeout"
require_relative "../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::MigrationPreparationTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Preparation = Provider::AccountData::MigrationPreparation
  Publisher = Ingestion::IdentityBootstrap
  Evidence = Ingestion::LegacyIdentityEvidence
  Fence = Provider::AccountData::LegacyWriterFence
  Copier = Provider::AccountData::MigrationCopier

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "fresh workers finish a bounded preparation without financial writes or activation" do
    with_identity_source do |context|
      entries = 3.times.map { |index| identity_entry(context, external_id: "up_preparation-#{index}") }
      before = identity_financial_snapshot(context)
      copy_before = context.control.reload.high_water_mark.deep_dup
      results = []

      queries = capture_sql_queries do
        results = finish_preparation(context)
      end

      result = results.last
      assert_equal "awaiting_acceptance", result.phase
      assert_equal context.control.id, result.control_id
      assert_equal 1, results.map(&:run_id).uniq.size
      assert result.run_id.present?
      assert_equal 1, result.inventory_count
      assert_equal 1, result.linked_count
      assert_equal 0, result.unlinked_count
      assert_equal 1, result.verified_identities_count
      assert_equal "partial", result.input_integration
      assert_equal 1, result.installed_inputs_count
      assert_equal 1, result.verified_inputs_count
      assert_equal [ "provider_logo/v1" ], context.control.reload.preparation_state.fetch("input_contract").fetch("handled_inputs")
      assert_no_financial_sql(queries)
      assert_equal before, identity_financial_snapshot(context)
      assert_equal copy_before, context.control.reload.high_water_mark
      assert_equal entries.map(&:id).sort, mappings(context).pluck(:entry_identity).sort
      assert_equal 3, identity_batches(context).count
      assert_paused(context)
      assert_provider_column_encrypted(context.control, :preparation_state, '"phase"')
      assert_provider_column_encrypted(context.mapping.reload, :preparation_state, '"format"')
    end
  end

  test "a shadow copy enters quiescence before financial evidence is published" do
    with_identity_source(quiesced: false) do |context|
      identity_entry(context, external_id: "up_from-shadow")
      assert context.control.shadow?
      before = identity_financial_snapshot(context)

      results = finish_preparation(context)

      assert_equal "awaiting_acceptance", results.last.phase
      assert_equal "quiesced", context.control.reload.high_water_mark.fetch("mode")
      assert_equal "verified", context.control.high_water_mark.fetch("phase")
      assert_equal context.control.high_water_mark.fetch("copy_run_id"), context.control.audit_results.fetch("copy_run_id")
      assert_equal before, identity_financial_snapshot(context)
      assert_equal 1, identity_batches(context).count
      assert_paused(context)
    end
  end

  test "preparation creates its first disabled copy when no migration control exists" do
    with_provider_encryption do
      family = families(:dylan_family)
      item = UpItem.create!(family: family, name: "Initial preparation", access_token: "private-initial-preparation")
      account = family.accounts.create!(name: "Existing empty account", currency: "USD", balance: BigDecimal("8.75"),
        accountable: Depository.new, status: "active")
      begin
        source = item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Checking", currency: "USD",
          current_balance: BigDecimal("8.75"), raw_transactions_payload: [])
        link = AccountProvider.create!(account: account, provider: source)
        before = account.reload.attributes
        assert_nil ProviderMigrationControl.find_by(legacy_type: "UpItem", legacy_id: item.id)
        result = nil
        100.times do
          result = Preparation.new(provider_key: "up", legacy_item_id: item.id, family: family, page_size: 1).run
          break if result.phase == "awaiting_acceptance"
        end

        assert_equal "awaiting_acceptance", result.phase
        assert_equal 1, result.linked_count
        assert_equal 1, result.verified_identities_count
        control = ProviderMigrationControl.find(result.control_id)
        assert control.quiescing?
        assert control.provider_connection.disabled?
        assert_equal source.id, link.reload.provider_id
        assert_equal control.provider_connection.external_accounts.sole.id, link.external_account_id
        assert_equal before, account.reload.attributes
        assert_empty control.provider_connection.syncs
        assert_empty SourceRecord.where(external_account_id: control.provider_connection.external_accounts.select(:id))
      ensure
        cleanup_identity_source(item, account)
      end
    end
  end

  test "Plaid EU preparation retains current and archive-only pending aliases for the original UUID" do
    with_identity_source(provider_key: "plaid", plaid_transactions: [ { transaction_id: "booked-preparation", pending: false,
      pending_transaction_id: "pending-preparation" } ]) do |context|
      entry = identity_entry(context, external_id: nil, source: nil, plaid_id: "booked-preparation", user_modified: true,
        extra: { "plaid" => { "pending" => false } })
      before = identity_financial_snapshot(context)

      result = finish_preparation(context).last

      assert_equal "awaiting_acceptance", result.phase
      assert_equal before, identity_financial_snapshot(context)
      assert_equal %w[booked-preparation pending-preparation], observations(context).order(:external_id).pluck(:external_id)
      assert_equal [ entry.id ], mappings(context).pluck(:entry_identity).uniq
      assert_equal %w[current retired_alias], mappings(context).order(:bootstrap_identity_role).pluck(:bootstrap_identity_role)
      assert_nil entry.reload.external_id
      assert_nil entry.source
      assert_equal "eu", identity_batches(context).sole.payload.fetch("plan").fetch("region")
      assert_paused(context)
    end
  end

  test "unlinked accounts are inventoried without manufacturing financial identity checkpoints" do
    with_identity_source(quiesced: false) do |context|
      identity_entry(context, external_id: "up_linked")
      unlinked = context.item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Discovered only", currency: "USD",
        current_balance: BigDecimal("17.25"), raw_transactions_payload: [])

      result = finish_preparation(context).last

      assert_equal 2, result.inventory_count
      assert_equal 1, result.linked_count
      assert_equal 1, result.unlinked_count
      assert_equal 1, result.verified_identities_count
      copied = context.control.provider_migration_mappings.find_by!(role: "external_account", legacy_id: unlinked.id)
      assert_nil copied.external_account.current_account
      assert_empty SourceRecord.where(external_account: copied.external_account)
      assert_empty ProviderSyncCheckpoint.where(external_account: copied.external_account, stream: Evidence::STREAM)
      assert copied.preparation_state.present?
      assert_equal 1, identity_batches(context).count
      assert_paused(context)
    end
  end

  test "explicit final reverification preserves the run original copy and proof after economic edits" do
    with_identity_source do |context|
      entry = identity_entry(context, external_id: "up_economic-edit")
      original = finish_preparation(context).last
      copy_before = context.control.reload.high_water_mark.deep_dup
      proof_before = identity_batches(context).order(:id).map(&:attributes)
      entry.update!(amount: BigDecimal("91.2345"), name: "My corrected description", user_modified: true)
      before = identity_financial_snapshot(context)
      results = []

      queries = capture_sql_queries do
        restarted = coordinator(context).restart_verification!
        assert_equal "verify_copy", restarted.phase
        assert_equal original.run_id, restarted.run_id
        results = finish_preparation(context)
      end

      assert_equal "awaiting_acceptance", results.last.phase
      assert_equal original.run_id, results.last.run_id
      assert_equal original.inventory_count, results.last.inventory_count
      assert_equal before, identity_financial_snapshot(context)
      assert_no_financial_sql(queries)
      assert_equal copy_before, context.control.reload.high_water_mark
      assert_equal proof_before, identity_batches(context).order(:id).map(&:attributes)
      assert_paused(context)
    end
  end

  test "a foreign family cannot start or mutate preparation for an existing copy" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_other-family")
      before = context.control.reload.attributes

      assert_no_difference [ "IngestionBatch.count", "SourceRecord.count", "EntrySource.count", "ProviderSyncCheckpoint.count" ] do
        assert_raises(Preparation::Conflict) { coordinator(context, family: families(:empty)).run }
      end

      assert_equal before, context.control.reload.attributes
      assert_empty context.mapping.reload.preparation_state
    end
  end

  test "source drift during preparation cannot replace the original copy or reopen the legacy writer" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_source-drift")
      advance_to(context, "identities")
      copy_before = context.control.reload.high_water_mark.deep_dup
      checksum = context.mapping.reload.source_checksum
      context.source.update_columns(current_balance: BigDecimal("999.99"))

      assert_raises(Copier::SourceChanged) { finish_preparation(context) }

      assert_equal copy_before, context.control.reload.high_water_mark
      assert_equal checksum, context.mapping.reload.source_checksum
      assert_not_equal "awaiting_acceptance", context.control.preparation_state["phase"]
      assert_paused(context)
    end
  end

  test "a previously unlinked account cannot become linked without invalidating the retained inventory" do
    with_identity_source(quiesced: false) do |context|
      identity_entry(context, external_id: "up_original-link")
      unlinked = context.item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Initially unlinked", currency: "USD",
        current_balance: BigDecimal("4"), raw_transactions_payload: [])
      advance_to(context, "identities")
      copied = context.control.provider_migration_mappings.find_by!(role: "external_account", legacy_id: unlinked.id)
      late_account = context.family.accounts.create!(name: "Late financial link", currency: "USD", balance: BigDecimal("4"),
        accountable: Depository.new, status: "active")
      begin
        # Simulate a lifecycle writer outside the declared fence. Preparation
        # must detect this change rather than silently change its disposition.
        AccountProvider.create!(account: late_account, provider: unlinked, external_account: copied.external_account)

        assert_raises(Copier::Conflict) { finish_preparation(context) }

        assert_not_equal "awaiting_acceptance", context.control.reload.preparation_state["phase"]
        assert_empty SourceRecord.where(external_account: copied.external_account)
        assert_paused(context)
      ensure
        Account::SourcePolicy.where(account_id: late_account.id).delete_all
        AccountProvider.where(account_id: late_account.id).delete_all
        late_account.reload.destroy!
      end
    end
  end

  test "equal account counts cannot conceal replacement of an inventoried source UUID" do
    with_identity_source(quiesced: false) do |context|
      identity_entry(context, external_id: "up_stable-inventory")
      replaced = context.item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Original unlinked source", currency: "USD",
        current_balance: BigDecimal("1"), raw_transactions_payload: [])
      result = advance_to(context, "identities")
      assert_equal 2, result.inventory_count
      replaced.delete
      context.item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Replacement source", currency: "USD",
        current_balance: BigDecimal("1"), raw_transactions_payload: [])
      assert_equal 2, context.item.up_accounts.count

      assert_raises(Copier::SourceChanged) { finish_preparation(context) }

      assert_not_equal "awaiting_acceptance", context.control.reload.preparation_state["phase"]
      assert_paused(context)
    end
  end

  test "a worker cannot reinterpret durable page progress using a different page size" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_page-contract")
      advance_to(context, "identities")
      before = context.control.reload.preparation_state.deep_dup

      assert_raises(Preparation::Conflict) { coordinator(context, page_size: 2).run }

      assert_equal before, context.control.reload.preparation_state
      assert_empty identity_batches(context)
      assert_paused(context)
    end
  end

  test "retained inventory blocks copy restart and legacy resume before any financial evidence exists" do
    with_identity_source do |context|
      advance_to(context, "identities")
      assert_empty identity_batches(context)
      assert_empty observations(context)
      original = preparation_storage(context)

      assert_raises(Copier::Conflict) { context.copier.run_quiesced(restart: true) }
      assert_raises(Copier::Conflict) { context.copier.run }
      assert_raises(Copier::Conflict) { context.copier.resume_legacy! }

      assert_equal original, preparation_storage(context)
      assert_paused(context)
    end
  end

  test "losing parent progress cannot adopt surviving account receipts or reopen copying" do
    with_identity_source do |context|
      advance_to(context, "identities")
      assert context.mapping.reload.preparation_state.present?
      assert_empty identity_batches(context)
      context.control.update!(preparation_state: {})
      original = preparation_storage(context)

      assert_raises(Preparation::Conflict) { coordinator(context).run }
      assert_raises(Copier::Conflict) { context.copier.run_quiesced(restart: true) }
      assert_raises(Copier::Conflict) { context.copier.resume_legacy! }

      assert_equal original, preparation_storage(context)
      assert_paused(context)
    end
  end

  test "replaying completed preparation does not manufacture new evidence or execution" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_completed-retry")
      first = finish_preparation(context).last
      proof_before = identity_batches(context).order(:id).map(&:attributes)
      result = nil

      assert_no_difference [ "SourceRecord.count", "EntrySource.count", "IngestionBatch.count", "ProviderSyncCheckpoint.count", "Sync.count" ] do
        result = coordinator(context).run
      end

      assert_equal "awaiting_acceptance", result.phase
      assert_equal first.run_id, result.run_id
      assert_equal first.verified_identities_count, result.verified_identities_count
      assert_equal proof_before, identity_batches(context).order(:id).map(&:attributes)
      assert_paused(context)
    end
  end

  test "removing a retained signing key blocks a fresh identity verification sweep" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_old-signing-key")
      finish_preparation(context)
      proof_before = identity_batches(context).order(:id).map(&:attributes)
      coordinator(context).restart_verification!
      Rails.application.config.x.provider_identity_signing = {
        active_key_id: "replacement", keys: { "replacement" => [ "r" * 32 ].pack("m0") }
      }

      assert_raises(Publisher::Conflict) { finish_preparation(context) }

      assert_equal proof_before, identity_batches(context).order(:id).map(&:attributes)
      assert_not_equal "awaiting_acceptance", context.control.reload.preparation_state["phase"]
      assert_paused(context)
    end
  end

  test "a concurrent legacy permit prevents preparation from recording progress" do
    with_identity_source(quiesced: false) do |context|
      before = context.control.reload.attributes
      result = Fence.with_item(context.item) do
        in_another_session do
          coordinator(context).run
          :unexpected_preparation
        rescue Fence::Busy
          :busy
        end
      end

      assert_equal :busy, result
      assert_equal before, context.control.reload.attributes
      assert_empty context.mapping.reload.preparation_state
      assert_empty identity_batches(context)
    end
  end

  test "a committed identity page survives a crash before coordinator progress commits" do
    with_identity_source do |context|
      2.times { |index| identity_entry(context, external_id: "up_child-commit-#{index}") }
      advance_to(context, "identities")
      before = identity_financial_snapshot(context)
      preparation_before = context.control.reload.preparation_state.deep_dup
      receipt_before = context.mapping.reload.preparation_state.deep_dup
      interrupted = coordinator(context)
      interrupted.expects(:save_progress!).once.raises(IOError, "private simulated interruption")

      assert_difference [ "SourceRecord.count", "EntrySource.count", "IngestionBatch.count", "ProviderSyncCheckpoint.count" ], 1 do
        assert_raises(IOError) { interrupted.run }
      end

      assert_equal preparation_before, context.control.reload.preparation_state
      assert_equal receipt_before, context.mapping.reload.preparation_state
      assert_equal 1, identity_checkpoint(context).state.fetch("captured_entries")
      assert_equal 1, identity_batches(context).count
      assert_equal before, identity_financial_snapshot(context)
      result = finish_preparation(context).last
      assert_equal "awaiting_acceptance", result.phase
      assert_equal 1, result.verified_identities_count
      assert_equal 2, identity_batches(context).count
      assert_equal 2, observations(context).count
      assert_equal 2, mappings(context).count
      assert_paused(context)
    end
  end

  test "a committed child verification restart can be repeated after its receipt commit fails" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_restart-commit")
      advance_to(context, "verify_identities")
      assert_equal "verified", identity_checkpoint(context).state.fetch("phase")
      preparation_before = context.control.reload.preparation_state.deep_dup
      receipt_before = context.mapping.reload.preparation_state.deep_dup
      proof_before = identity_batches(context).order(:id).map(&:attributes)
      interrupted = coordinator(context)
      interrupted.expects(:save_progress!).once.raises(IOError, "private interrupted restart receipt")

      assert_no_difference [ "SourceRecord.count", "EntrySource.count", "IngestionBatch.count", "ProviderSyncCheckpoint.count" ] do
        assert_raises(IOError) { interrupted.run }
      end

      assert_equal "verify", identity_checkpoint(context).state.fetch("phase")
      assert_equal preparation_before, context.control.reload.preparation_state
      assert_equal receipt_before, context.mapping.reload.preparation_state
      assert_nil context.mapping.preparation_state["verification_identity"]
      result = finish_preparation(context).last
      assert_equal "awaiting_acceptance", result.phase
      assert_equal 1, result.verified_identities_count
      assert_equal proof_before, identity_batches(context).order(:id).map(&:attributes)
      assert_paused(context)
    end
  end

  test "a completed child verification is counted once after a failed parent receipt commit" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_final-child-commit")
      advance_to(context, "verify_identities")
      coordinator(context).run # Commit the restart and its parent receipt.
      assert_equal "verify", context.mapping.reload.preparation_state.fetch("verification_identity").fetch("phase")
      preparation_before = context.control.reload.preparation_state.deep_dup
      receipt_before = context.mapping.reload.preparation_state.deep_dup
      proof_before = identity_batches(context).order(:id).map(&:attributes)
      interrupted = coordinator(context)
      interrupted.expects(:save_progress!).once.raises(IOError, "private interrupted final receipt")

      assert_no_difference [ "SourceRecord.count", "EntrySource.count", "IngestionBatch.count", "ProviderSyncCheckpoint.count" ] do
        assert_raises(IOError) { interrupted.run }
      end

      assert_equal "verified", identity_checkpoint(context).state.fetch("phase")
      assert_equal preparation_before, context.control.reload.preparation_state
      assert_equal receipt_before, context.mapping.reload.preparation_state
      result = finish_preparation(context).last
      assert_equal 1, result.verified_identities_count
      assert_equal proof_before, identity_batches(context).order(:id).map(&:attributes)
      assert_paused(context)
    end
  end

  test "an empty account cannot replace the checkpoint named by its saved initial identity receipt" do
    with_identity_source do |context|
      advance_to(context, "identities")
      coordinator(context).run
      receipt = context.mapping.reload.preparation_state.fetch("identity")
      assert_equal "verify", receipt.fetch("phase")
      assert_equal 0, receipt.fetch("captured_entries")
      assert_empty identity_batches(context)
      assert_empty observations(context)
      replacement = replace_identity_checkpoint(context)
      assert_not_equal receipt.fetch("checkpoint_id"), replacement.id
      before = preparation_storage(context)

      assert_raises(Preparation::Conflict) { coordinator(context).run }

      assert_equal before, preparation_storage(context)
      assert_equal replacement.id, identity_checkpoint(context).id
      assert_paused(context)
    end
  end

  test "an empty account cannot replace the checkpoint named by its saved final restart receipt" do
    with_identity_source do |context|
      advance_to(context, "verify_identities")
      coordinator(context).run
      receipt = context.mapping.reload.preparation_state.fetch("verification_identity")
      assert_equal "verify", receipt.fetch("phase")
      assert_equal 0, receipt.fetch("captured_entries")
      assert_empty identity_batches(context)
      assert_empty observations(context)
      replacement = replace_identity_checkpoint(context)
      assert_not_equal receipt.fetch("checkpoint_id"), replacement.id
      before = preparation_storage(context)

      assert_raises(Preparation::Conflict) { coordinator(context).run }

      assert_equal before, preparation_storage(context)
      assert_equal replacement.id, identity_checkpoint(context).id
      assert_paused(context)
    end
  end

  test "oversized encrypted connection progress rejects continuation without publishing evidence" do
    with_identity_source do |context|
      advance_to(context, "identities")
      write_oversized_document(context.control.reload, :preparation_state)
      before = preparation_storage(context)

      error = assert_raises(Preparation::Conflict) { coordinator(context).run }

      assert_match(/bound|oversized/i, error.message)
      assert_equal before, preparation_storage(context)
      assert_empty identity_batches(context)
      assert_paused(context)
    end
  end

  test "oversized encrypted account receipts reject continuation without publishing evidence" do
    with_identity_source do |context|
      advance_to(context, "identities")
      write_oversized_document(context.mapping.reload, :preparation_state)
      before = preparation_storage(context)

      error = assert_raises(Preparation::Conflict) { coordinator(context).run }

      assert_match(/bound|oversized/i, error.message)
      assert_equal before, preparation_storage(context)
      assert_empty identity_batches(context)
      assert_paused(context)
    end
  end

  test "oversized encrypted identity checkpoints reject continuation before any new child publication" do
    with_identity_source do |context|
      advance_to(context, "identities")
      coordinator(context).run
      write_oversized_document(identity_checkpoint(context), :state)
      before = preparation_storage(context)

      error = assert_raises(Preparation::Conflict) { coordinator(context).run }

      assert_match(/bound|oversized/i, error.message)
      assert_equal before, preparation_storage(context)
      assert_empty identity_batches(context)
      assert_paused(context)
    end
  end

  private
    def coordinator(context, family: context.family, page_size: 1)
      Preparation.new(provider_key: context.control.provider_key, legacy_item_id: context.item.id, family: family, page_size: page_size)
    end

    def finish_preparation(context)
      results = []
      100.times do
        results << coordinator(context).run
        return results if results.last.phase == "awaiting_acceptance"
      end
      flunk "Preparation did not finish within its bounded continuation calls"
    end

    def advance_to(context, phase)
      100.times do
        result = coordinator(context).run
        return result if result.phase == phase
        flunk "Preparation passed the expected phase #{phase}" if result.phase == "awaiting_acceptance"
      end
      flunk "Preparation did not reach #{phase}"
    end

    def identity_batches(context)
      context.external.provider_connection.ingestion_batches.where(stream: Evidence::STREAM)
    end

    def identity_checkpoint(context)
      ProviderSyncCheckpoint.find_by!(provider_connection_id: context.control.provider_connection_id,
        external_account: context.external, stream: Evidence::STREAM, scope_key: "account:#{context.external.id}")
    end

    def replace_identity_checkpoint(context)
      original = identity_checkpoint(context)
      attributes = original.attributes.except("id", "created_at", "updated_at", "lock_version")
      original.delete
      ProviderSyncCheckpoint.create!(attributes)
    end

    def write_oversized_document(record, attribute)
      # Random bytes prevent encryption compression from making a repetitive
      # fixture fit under the stored-byte bound being exercised.
      document = record.public_send(attribute).merge("private_padding" => SecureRandom.base64(3 * 1024 * 1024))
      record.update!(attribute => document)
      bytes = record.class.where(id: record.id).pick(Arel.sql("octet_length(#{attribute})"))
      assert_operator bytes, :>, 2 * 1024 * 1024
    end

    def preparation_storage(context)
      { "control" => context.control.reload.attributes,
        "mappings" => context.control.provider_migration_mappings.order(:id).map(&:attributes),
        "batches" => context.control.provider_connection.ingestion_batches.order(:id).map(&:attributes),
        "checkpoints" => context.control.provider_connection.provider_sync_checkpoints.order(:id).map(&:attributes) }
    end

    def observations(context)
      SourceRecord.where(external_account: context.external)
    end

    def mappings(context)
      EntrySource.where(bootstrap_external_account: context.external)
    end

    def assert_paused(context)
      control = context.control.reload
      connection = control.provider_connection.reload
      assert control.quiescing?
      assert connection.disabled?
      assert_equal 0, control.writer_epoch
      assert_equal 0, connection.writer_epoch
      assert_nil control.lease_owner
      assert_nil connection.lease_owner
      assert_empty connection.syncs
      assert_raises(Fence::OwnershipChanged) { Fence.with_item(context.item) { flunk "Preparation must retain the legacy pause" } }
    end

    def in_another_session(&block)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      worker = Thread.new { ApplicationRecord.connection_pool.with_connection(&block) }
      Timeout.timeout(5) { worker.value }
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end
end
