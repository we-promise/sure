require "test_helper"
require_relative "../../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::Plaid::CachedChangeJournalTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Journal = Provider::AccountData::Plaid::CachedChangeJournal
  Copier = Provider::AccountData::MigrationCopier
  Preparation = Provider::AccountData::MigrationPreparation
  Value = Provider::AccountData::MigrationValue

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "fresh workers retain every physical occurrence in legacy order without financial or live cursor writes" do
    cache = complete_cache(modified: [ raw_transaction("same", amount: "1.23"), raw_transaction("same", amount: 2.34) ],
      added: [ raw_transaction("same", amount: "3.45"), raw_transaction("new") ], removed: [ { "transaction_id" => "same" } ])
    with_cached_source(cache: cache) do |context|
      identity_entry(context, external_id: nil, source: nil, plaid_id: "same", user_modified: true, import_locked: true)
      before = unchanged_storage(context)
      result = nil
      queries = capture_sql_queries { result = finish(context, page_size: 2) }

      assert result.recorded?
      assert_equal 3, result.captured_pages
      assert_equal 3, result.verified_pages
      assert_equal 5, result.observations
      assert_equal 0, result.blockers
      pages = batches(context).order(:sequence).to_a
      assert_equal [ 0, 1, 2 ], pages.map(&:sequence)
      observations = pages.flat_map { |batch| decoded_page(batch).fetch("plan").fetch("observations") }
      assert_equal %w[modified modified added added removed], observations.map { |row| row.fetch("section") }
      assert_equal [ 0, 1, 0, 1, 0 ], observations.map { |row| row.fetch("source_index") }
      assert_equal [ 0, 1, 2, 3, 4 ], observations.map { |row| row.fetch("ordinal") }
      assert_equal %w[same same same new same], observations.map { |row| row.fetch("external_id") }
      assert_equal [ BigDecimal("1.23"), BigDecimal("2.34"), BigDecimal("3.45") ],
        observations.first(3).map { |row| row.fetch("canonical").fetch("attributes").fetch(:amount) }
      observations.first(4).each do |row|
        attributes = row.fetch("canonical").fetch("attributes")
        assert_instance_of BigDecimal, attributes.fetch(:amount)
        assert_instance_of Date, attributes.fetch(:date)
        assert_equal Date.new(2026, 9, 1), attributes.fetch(:date)
      end
      pages.each do |batch|
        payload = decoded_page(batch)
        assert_equal batch.id, payload.fetch("batch_id")
        assert_equal result.checkpoint_id, payload.fetch("checkpoint_id")
        assert_equal batch.sequence, payload.fetch("sequence")
        assert payload.fetch("source_policy").is_a?(Hash)
        assert_equal false, payload.fetch("plan").fetch("cursor_accepted")
        assert Ingestion::IdentitySigningKeys.configured.verify!(payload.fetch("signature"), Value.dump(payload.except("signature")))
        assert batch.applied?
        assert_equal "migration", batch.origin_kind
        assert_equal "unknown", batch.mode
        assert_not batch.complete?
        assert_nil batch.sync_id
        assert_nil batch.external_account_id
        assert_empty batch.coverage
      end
      assert_provider_column_encrypted(pages.first, :payload, "Private cached description")
      assert_provider_column_encrypted(ProviderSyncCheckpoint.find(result.checkpoint_id), :state, "retained-private-cursor")
      assert_no_financial_sql(queries)
      assert_equal before, unchanged_storage(context)
      assert_empty connection(context).syncs
      assert_empty connection(context).provider_sync_checkpoints.where(stream: "transactions")
      assert_empty SourceRecord.where(external_account_id: connection(context).external_accounts.select(:id))
      assert context.control.reload.quiescing?
      assert connection(context).disabled?
    end
  end

  test "pending exclusions and unlinked accounts remain explicit observations" do
    cache = complete_cache(added: [ raw_transaction("pending", pending: true), raw_transaction("booked", pending_transaction_id: "pending") ])
    with_cached_source(cache: cache, include_pending: false, extra_caches: [ complete_cache(removed: [ { "transaction_id" => "unlinked-removal" } ]) ]) do |context|
      result = finish(context, page_size: 1)
      payloads = batches(context).order(:sequence).map { |batch| decoded_page(batch) }
      linked = payloads.select { |payload| payload.dig("plan", "source_account", "disposition") == "linked" }
      unlinked = payloads.select { |payload| payload.dig("plan", "source_account", "disposition") == "unlinked" }

      assert_equal 3, result.observations
      assert_equal 0, result.blockers
      assert_equal %w[pending_excluded upsert_observation], linked.flat_map { |payload| payload.dig("plan", "observations") }.map { |row| row.fetch("disposition") }
      assert_equal true, linked.first.dig("plan", "observations", 0, "raw", "pending")
      assert_equal "pending", linked.last.fetch("plan").fetch("observations").sole.fetch("canonical").fetch("attributes").fetch(:pending_external_id)
      assert_nil unlinked.sole.fetch("source_policy")
      assert_equal "removal_observation", unlinked.sole.dig("plan", "observations", 0, "disposition")
      assert_empty SourceRecord.where(external_account_id: connection(context).external_accounts.select(:id))
    end
  end

  test "malformed rows and missing caches are journaled as blockers rather than discarded" do
    with_cached_source(cache: complete_cache(modified: [ raw_transaction("bad", amount: "invalid") ],
      removed: [ { "transaction_id" => "valid-removal" } ]), extra_caches: [ {} ]) do |context|
      before = unchanged_storage(context)
      result = finish(context, page_size: 1)
      payloads = batches(context).order(:sequence).map { |batch| decoded_page(batch) }

      assert result.recorded?
      assert_equal 2, result.observations
      assert_equal 2, result.blockers
      assert_equal %w[cached_change_set_not_recorded cached_transaction_normalization_failed],
        payloads.flat_map { |payload| payload.fetch("plan").fetch("blockers") }.map { |row| row.fetch("code") }.sort
      assert payloads.all? { |payload| payload.dig("plan", "cursor_accepted") == false }
      assert_equal before, unchanged_storage(context)
    end
  end

  test "empty caches and zero-account copies retain terminal evidence without claiming coverage" do
    with_cached_source(cache: complete_cache) do |context|
      result = finish(context)
      assert result.recorded?
      assert_equal 1, result.captured_pages
      assert_equal 0, result.observations
      assert_equal 0, result.blockers
      assert_equal "account_cache_generation_and_unassigned_removals_not_retained", decoded_page(batches(context).sole).dig("plan", "historical_coverage")
    end
    with_empty_source do |context|
      result = finish(context)
      assert result.recorded?
      assert_equal 1, result.captured_pages
      assert_equal 0, result.observations
      payload = decoded_page(batches(context).sole)
      assert_nil payload.fetch("plan").fetch("source_account")
      assert_nil payload.fetch("source_policy")
      assert_equal false, payload.fetch("plan").fetch("cursor_accepted")
      ProviderSyncCheckpoint.find(result.checkpoint_id).delete
      assert_raises(Journal::Conflict) { journal(context).run }
      assert_equal 1, batches(context).count
    end
  end

  test "checkpoint persistence failure rolls back its page and a fresh worker records it once" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("first"), raw_transaction("second") ])) do |context|
      before = unchanged_storage(context)
      ProviderSyncCheckpoint.any_instance.expects(:save!).once.raises(ActiveRecord::RecordInvalid)
      assert_raises(ActiveRecord::RecordInvalid) { journal(context, page_size: 1).run }
      assert_empty batches(context)
      assert_empty checkpoints(context)
      assert_equal before, unchanged_storage(context)
      ProviderSyncCheckpoint.any_instance.unstub(:save!)

      result = finish(context, page_size: 1)
      assert_equal 2, result.captured_pages
      assert_equal 2, batches(context).count
      assert_equal before, unchanged_storage(context)
    end
  end

  test "committed progress resumes and terminal retries preserve the original signed pages" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("first"), raw_transaction("second") ])) do |context|
      first = journal(context, page_size: 1).run
      assert_equal "capture", first.phase
      assert_equal 1, first.captured_pages
      original_page = IngestionBatch.find(first.batch_id).attributes
      result = finish(context, page_size: 1)
      assert_equal first.checkpoint_id, result.checkpoint_id
      assert_equal original_page, IngestionBatch.find(first.batch_id).attributes
      pages = batches(context).order(:sequence).map(&:attributes)

      retrying = journal(context, page_size: 1)
      again = retrying.run
      assert again.recorded?
      assert again.replayed
      assert_equal result.checkpoint_id, again.checkpoint_id
      assert_equal result.batch_id, again.batch_id
      assert_equal pages, batches(context).order(:sequence).map(&:attributes)
      [ again, retrying ].each do |object|
        refute_includes object.inspect, "retained-private-cursor"
        refute_includes object.inspect, "Private cached description"
      end
    end
  end

  test "reverification retains original page receipts despite legitimate financial edits" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("entry") ])) do |context|
      entry = identity_entry(context, external_id: nil, source: nil, plaid_id: "entry")
      result = finish(context)
      pages = batches(context).order(:sequence).map(&:attributes)
      entry.update!(amount: BigDecimal("99.87"), name: "User correction", user_modified: true)
      before = identity_financial_snapshot(context)

      restarted = journal(context).restart_verification!
      assert_equal "verify", restarted.phase
      assert_equal result.checkpoint_id, restarted.checkpoint_id
      again = finish(context)
      assert again.recorded?
      assert_equal result.captured_pages, again.captured_pages
      assert_equal result.verified_pages, again.verified_pages
      assert_equal pages, batches(context).order(:sequence).map(&:attributes)
      assert_equal before, identity_financial_snapshot(context)
    end
  end

  test "journal and permanent financial identity publication retain distinct proof and checkpoints" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("booked") ])) do |context|
      entry = identity_entry(context, external_id: nil, source: nil, plaid_id: "booked", extra: { "plaid" => { "pending" => false } })
      result = finish(context)
      pages = batches(context).order(:sequence).map(&:attributes)
      before = identity_financial_snapshot(context)
      publisher = Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family, page_size: 1)
      identity_result = nil
      10.times do
        identity_result = publisher.run
        break if identity_result.verified?
      end

      assert identity_result.verified?
      refute_equal result.checkpoint_id, identity_result.checkpoint_id
      assert_equal [ entry.id ], EntrySource.where(bootstrap_external_account: context.external).pluck(:entry_identity)
      assert_equal before, identity_financial_snapshot(context)
      journal(context).restart_verification!
      repeated = finish(context)
      assert repeated.recorded?
      assert_equal result.checkpoint_id, repeated.checkpoint_id
      assert_equal pages, batches(context).order(:sequence).map(&:attributes)
      assert_empty connection(context).provider_sync_checkpoints.where(stream: "transactions")
      assert_equal before, identity_financial_snapshot(context)
    end
  end

  test "lost or replaced checkpoint cannot adopt retained pages" do
    %i[missing replaced].each do |failure|
      with_cached_source(cache: complete_cache(added: [ raw_transaction("first"), raw_transaction("second") ])) do |context|
        first = journal(context, page_size: 1).run
        saved = ProviderSyncCheckpoint.find(first.checkpoint_id)
        replacement = saved.attributes.except("id", "created_at", "updated_at")
        saved.delete
        ProviderSyncCheckpoint.create!(replacement) if failure == :replaced
        before = batches(context).map(&:attributes)

        assert_raises(Journal::Conflict) { journal(context, page_size: 1).run }
        assert_equal before, batches(context).map(&:attributes)
      end
    end
  end

  test "processing and application drift cannot advance the captured journal" do
    %i[pending page_size deployment].each do |change|
      with_cached_source(cache: complete_cache(added: [ raw_transaction("first"), raw_transaction("second") ])) do |context|
        first = journal(context, page_size: 1).run
        before = journal_storage(context)
        case change
        when :pending then Setting.syncs_include_pending = false
        when :deployment then Setting["plaid_eu_secret"] = "changed-private-application"
        end

        assert_raises(Journal::Conflict) { journal(context, page_size: change == :page_size ? 2 : 1).run }
        assert_equal first.checkpoint_id, checkpoints(context).sole.id
        assert_equal before, journal_storage(context)
      end
    end
  end

  test "source authority revision drift invalidates the journal even when the selected provider returns" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("first"), raw_transaction("second") ])) do |context|
      journal(context, page_size: 1).run
      before = journal_storage(context)
      policy = Account::SourcePolicy.active.find_by!(account: context.account, resource: "transactions")
      context.account.with_lock do
        policy.update!(active: false)
        Account::SourcePolicy.select!(account: context.account, account_provider: context.link, resource: "transactions")
      end

      assert_raises(Journal::Conflict) { journal(context, page_size: 1).run }
      assert_equal before, journal_storage(context)
    end
  end

  test "changed copied source rejects continuation without replacing evidence" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("first"), raw_transaction("second") ])) do |context|
      journal(context, page_size: 1).run
      before = journal_storage(context)
      context.source.update!(raw_transactions_payload: complete_cache)

      assert_raises(Journal::Conflict) { journal(context, page_size: 1).run }
      assert_equal before, journal_storage(context)
    end
  end

  test "an earlier page hole or unsigned content change prevents completed verification" do
    %i[missing tampered].each do |failure|
      with_cached_source(cache: complete_cache(added: [ raw_transaction("first"), raw_transaction("second") ])) do |context|
        journal(context, page_size: 1).run
        journal(context, page_size: 1).run
        first = batches(context).order(:sequence).first!
        if failure == :missing
          first.delete
        else
          payload = decoded_page(first).deep_dup
          payload.fetch("plan").fetch("observations").first.fetch("raw")["amount"] = "999.99"
          IngestionBatch.where(id: first.id).update_all(payload: { "format" => Journal::FORMAT, "document" => Value.dump(payload) })
        end
        before = identity_financial_snapshot(context)

        assert_raises(Journal::Conflict) { finish(context, page_size: 1) }
        assert_equal before, identity_financial_snapshot(context)
        assert_not_equal "recorded", checkpoints(context).sole.state.fetch("phase")
      end
    end
  end

  test "compressed checkpoint state exceeding the decoded bound rejects before replanning" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("first"), raw_transaction("second") ])) do |context|
      result = journal(context, page_size: 1).run
      checkpoint = ProviderSyncCheckpoint.find(result.checkpoint_id)
      oversized = checkpoint.state.deep_dup
      private_value = "private-oversized-journal-context"
      oversized.fetch("context")["padding"] = private_value * (Journal::MAX_STATE_BYTES / private_value.bytesize + 1)
      checkpoint.update_columns(state: oversized)
      stored_bytes = ProviderSyncCheckpoint.where(id: checkpoint.id).pick(Arel.sql("octet_length(state)"))
      assert_operator stored_bytes, :<=, Journal::MAX_STATE_BYTES * 2
      assert_operator Value.dump(checkpoint.reload.state).bytesize, :>, Journal::MAX_STATE_BYTES
      before = journal_storage(context)
      financial = identity_financial_snapshot(context)
      Provider::AccountData::Plaid::CheckpointBootstrapPlan.any_instance.expects(:page).never

      error = assert_raises(Journal::Conflict) { journal(context, page_size: 1).run }

      assert_match(/decoded bound/, error.message)
      refute_includes error.message, private_value
      assert_nil error.cause
      assert_equal before, journal_storage(context)
      assert_equal financial, identity_financial_snapshot(context)
      assert_equal 1, batches(context).count
    end
  end

  test "journal evidence prevents copy restart and legacy resumption even without financial identity mappings" do
    with_cached_source(cache: complete_cache) do |context|
      finish(context)
      before = journal_storage(context)
      assert_empty EntrySource.where(bootstrap_external_account_id: connection(context).external_accounts.select(:id))

      assert_raises(Copier::Conflict) { context.copier.run_quiesced(restart: true) }
      assert_raises(Copier::Conflict) { context.copier.resume_legacy! }
      assert_equal before, journal_storage(context)
      assert context.control.reload.quiescing?
      assert connection(context).disabled?
    end
  end

  test "foreign family and shadow-only copies cannot create a migration journal" do
    with_cached_source(cache: complete_cache) do |context|
      assert_raises(ArgumentError) { Journal.new(control: context.control, family: families(:empty)) }
      assert_empty batches(context)
      assert_empty checkpoints(context)
    end
    with_identity_source(provider_key: "plaid", quiesced: false) do |context|
      assert_raises(Journal::Conflict) { journal(context).run }
      assert_empty batches(context)
      assert_empty checkpoints(context)
    end
  end

  test "Plaid EU preparation finishes its observation journal separately from installed inputs" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("booked"), raw_transaction("unpublished") ])) do |context|
      identity_entry(context, external_id: nil, source: nil, plaid_id: "booked", extra: { "plaid" => { "pending" => false } })
      before = identity_financial_snapshot(context)
      entering = advance_preparation(context, phase: "journal_cached_changes")
      assert_empty batches(context)
      result = finish_preparation(context)
      state = context.control.reload.preparation_state

      assert result.awaiting_acceptance?
      assert_equal entering.run_id, result.run_id
      assert_equal entering.installed_inputs_count, result.installed_inputs_count
      assert_equal entering.verified_inputs_count, result.verified_inputs_count
      assert_equal [ Journal::FORMAT ], state.fetch("input_contract").fetch("observation_journals")
      assert_equal false, state.fetch("input_contract").fetch("upstream_history_complete")
      assert_equal "recorded", state.fetch("cached_changes").fetch("phase")
      assert_equal 2, state.fetch("cached_changes").fetch("observations")
      assert_equal state.fetch("verification_run_id"), state.fetch("cached_change_verification_run_id")
      assert_equal before, identity_financial_snapshot(context)
      assert context.control.quiescing?
      assert connection(context).disabled?
      assert_empty connection(context).syncs
      assert_empty connection(context).provider_sync_checkpoints.where(stream: "transactions")
    end
  end

  test "preparation preserves a pending ledger baseline while journaling its unapplied cached settlement" do
    cache = complete_cache(added: [ raw_transaction("booked", pending_transaction_id: "pending", amount: "999.99") ])
    with_cached_source(cache: cache) do |context|
      entry = identity_entry(context, external_id: "pending", extra: { "plaid" => { "pending" => true } },
        user_modified: true, import_locked: true, excluded: true, locked_attributes: { "name" => true })
      before = identity_financial_snapshot(context)
      result = nil

      queries = capture_sql_queries { result = finish_preparation(context) }

      assert result.awaiting_acceptance?
      assert_no_financial_sql(queries)
      assert_equal before, identity_financial_snapshot(context)
      source = SourceRecord.where(external_account: context.external).sole
      assert_equal "pending", source.external_id
      assert source.pending?
      assert_equal entry.id, source.entry_source.entry_id
      assert_equal "current", source.entry_source.bootstrap_identity_role
      assert_equal "migration", source.entry_source.bootstrap_batch.origin_kind
      observation = batches(context).flat_map { |batch| decoded_page(batch).fetch("plan").fetch("observations") }.sole
      assert_equal "booked", observation.fetch("external_id")
      assert_equal "upsert_observation", observation.fetch("disposition")
      assert_equal "pending", observation.fetch("canonical").fetch("attributes").fetch(:pending_external_id)
      assert_equal BigDecimal("999.99"), observation.fetch("canonical").fetch("attributes").fetch(:amount)
      assert_empty connection(context).provider_sync_checkpoints.where(stream: "transactions")
      assert_empty connection(context).syncs
      assert context.control.reload.quiescing?
      assert connection(context).disabled?
    end
  end

  test "preparation resumes an exact child page committed before its parent receipt" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("first"), raw_transaction("second") ])) do |context|
      advance_preparation(context, phase: "journal_cached_changes")
      preparation(context).run
      prior = context.control.reload.preparation_state.deep_dup
      assert_equal 1, prior.fetch("cached_changes").fetch("captured_pages")
      interrupted = preparation(context)
      interrupted.expects(:save_progress!).once.raises(RuntimeError, "Simulated crash after child commit")

      assert_raises(RuntimeError) { interrupted.run }

      assert_equal prior, context.control.reload.preparation_state
      assert_equal 2, batches(context).count
      checkpoint = checkpoints(context).sole
      assert_equal 2, checkpoint.state.fetch("captured_pages")
      assert_equal "verify", checkpoint.state.fetch("phase")
      pages = batches(context).order(:sequence).map(&:attributes)
      result = finish_preparation(context)
      assert result.awaiting_acceptance?
      assert_equal prior.fetch("run_id"), result.run_id
      assert_equal checkpoint.id, context.control.reload.preparation_state.fetch("cached_changes").fetch("checkpoint_id")
      assert_equal pages, batches(context).order(:sequence).map(&:attributes)
    end
  end

  test "preparation reverifies the existing journal without replacing copy run checkpoint or signed pages" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("retained") ])) do |context|
      first = finish_preparation(context)
      previous = context.control.reload.preparation_state.deep_dup
      copy_run_id = context.control.high_water_mark.fetch("copy_run_id")
      pages = batches(context).order(:sequence).map(&:attributes)

      restarted = preparation(context).restart_verification!
      assert_equal "verify_copy", restarted.phase
      assert_equal first.run_id, restarted.run_id
      result = finish_preparation(context)
      current = context.control.reload.preparation_state

      assert result.awaiting_acceptance?
      assert_equal first.run_id, result.run_id
      refute_equal previous.fetch("verification_run_id"), current.fetch("verification_run_id")
      assert_equal current.fetch("verification_run_id"), current.fetch("cached_change_verification_run_id")
      assert_equal previous.fetch("cached_changes").fetch("checkpoint_id"), current.fetch("cached_changes").fetch("checkpoint_id")
      assert_equal "recorded", current.fetch("cached_changes").fetch("phase")
      assert_equal copy_run_id, context.control.high_water_mark.fetch("copy_run_id")
      assert_equal pages, batches(context).order(:sequence).map(&:attributes)
      assert_equal first.installed_inputs_count, result.installed_inputs_count
      assert_equal first.verified_inputs_count, result.verified_inputs_count
    end
  end

  test "preparation cannot restart verification in the middle of journal capture" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("first"), raw_transaction("second") ])) do |context|
      advance_preparation(context, phase: "journal_cached_changes")
      preparation(context).run
      prior = context.control.reload.preparation_state.deep_dup
      assert_equal "capture", prior.fetch("cached_changes").fetch("phase")
      before = journal_storage(context)

      assert_raises(Preparation::Conflict) { preparation(context).restart_verification! }

      assert_equal prior, context.control.reload.preparation_state
      assert_equal before, journal_storage(context)
      assert finish_preparation(context).awaiting_acceptance?
      assert_equal 2, batches(context).count
    end
  end

  private
    def with_cached_source(cache:, include_pending: true, extra_caches: [])
      previous = Setting.unscoped.find_by(var: "syncs_include_pending")
      previous_value = previous&.value
      Setting.syncs_include_pending = include_pending
      with_env_overrides("PLAID_INCLUDE_PENDING" => nil) do
        with_identity_source(provider_key: "plaid", quiesced: false) do |context|
          context.item.update!(next_cursor: "retained-private-cursor", available_products: [ "transactions" ])
          context.source.update!(raw_transactions_payload: bind_cache(cache, context.source.plaid_id))
          extra_caches.each_with_index do |other_cache, index|
            source = context.item.plaid_accounts.create!(plaid_id: SecureRandom.uuid, name: "Unlinked #{index}", currency: "USD",
              plaid_type: "depository", current_balance: BigDecimal("1"))
            source.update!(raw_transactions_payload: bind_cache(other_cache, source.plaid_id))
          end
          20.times do
            context.copier.run_quiesced
            break if context.control.reload.high_water_mark["phase"] == "verified"
          end
          assert context.control.quiescing?
          assert_equal "verified", context.control.high_water_mark.fetch("phase")
          context.mapping.reload
          yield context
        end
      end
    ensure
      if previous
        Setting.syncs_include_pending = previous_value
      else
        Setting.unscoped.where(var: "syncs_include_pending").destroy_all
      end
      Setting.clear_cache
    end

    def with_empty_source
      with_identity_plaid_application do
        with_provider_encryption do
          family = families(:dylan_family)
          item = PlaidItem.create!(family: family, name: "Empty journal", plaid_region: "eu", plaid_id: SecureRandom.uuid,
            access_token: "private-empty-token", available_products: [ "transactions" ])
          copier = Copier.new(provider_key: "plaid", legacy_item_id: item.id)
          control = nil
          10.times do
            control = copier.run_quiesced.reload
            break if control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", control.high_water_mark.fetch("phase")
          yield IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: nil, account: nil, link: nil,
            copier: copier, control: control, mapping: nil, external: nil)
        ensure
          connection = control&.provider_connection
          connection&.provider_sync_checkpoints&.delete_all
          ProviderMigrationAccountBinding.where(family_id: control.family_id,
            provider_migration_mapping_id: control.provider_migration_mappings.select(:id)).delete_all if control
          connection&.ingestion_batches&.delete_all
          control&.provider_migration_mappings&.delete_all
          control&.delete
          connection&.destroy!
          item&.delete
        end
      end
    end

    def complete_cache(modified: [], added: [], removed: [])
      { "modified" => modified, "added" => added, "removed" => removed }
    end

    def raw_transaction(id, **attributes)
      { "transaction_id" => id, "account_id" => "fixture-account", "amount" => "12.34", "iso_currency_code" => "USD",
        "date" => "2026-09-01", "pending" => false, "original_description" => "Private cached description" }.merge(attributes.stringify_keys)
    end

    def bind_cache(cache, account_id)
      result = cache.deep_dup
      if result.is_a?(Hash)
        result.each_value do |rows|
          next unless rows.is_a?(Array)
          rows.each { |row| row["account_id"] = account_id if row.is_a?(Hash) && row["account_id"] == "fixture-account" }
        end
      end
      result
    end

    def journal(context, page_size: 100)
      Journal.new(control: context.control.reload, family: context.family, page_size: page_size)
    end

    def preparation(context)
      Preparation.new(provider_key: "plaid", legacy_item_id: context.item.id, family: context.family, page_size: 1)
    end

    def advance_preparation(context, phase:)
      100.times do
        result = preparation(context).run
        return result if result.phase == phase
      end
      flunk "Plaid preparation did not reach #{phase} within its bounded steps"
    end

    def finish_preparation(context)
      advance_preparation(context, phase: "awaiting_acceptance")
    end

    def finish(context, page_size: 100)
      40.times do
        result = journal(context, page_size: page_size).run
        return result if result.recorded?
      end
      flunk "Cached change journal did not complete its bounded capture and verification"
    end

    def connection(context)
      context.control.reload.provider_connection
    end

    def batches(context)
      connection(context).ingestion_batches.where(stream: Journal::STREAM)
    end

    def checkpoints(context)
      connection(context).provider_sync_checkpoints.where(stream: Journal::STREAM)
    end

    def journal_storage(context)
      { "batches" => batches(context).order(:sequence).map(&:attributes), "checkpoints" => checkpoints(context).order(:id).map(&:attributes) }
    end

    def decoded_page(batch)
      Value.load(batch.payload.fetch("document"))
    end

    def unchanged_storage(context)
      { "financial" => identity_financial_snapshot(context), "item" => context.item.reload.attributes,
        "sources" => context.item.plaid_accounts.order(:id).map(&:attributes), "control" => context.control.reload.attributes,
        "mappings" => context.control.provider_migration_mappings.order(:id).map(&:attributes),
        "connection" => connection(context).attributes, "external_accounts" => connection(context).external_accounts.order(:id).map(&:attributes),
        "batches" => connection(context).ingestion_batches.where.not(stream: Journal::STREAM).order(:id).map(&:attributes),
        "checkpoints" => connection(context).provider_sync_checkpoints.where.not(stream: Journal::STREAM).order(:id).map(&:attributes) }
    end
end
