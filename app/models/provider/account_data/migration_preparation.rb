require "digest"
require "securerandom"

# Coordinates bounded copy and financial-identity preparation. Its terminal state
# is an inventory report, never authority to enable a native writer. Ordinary
# preparation pages commit independently under the exclusive legacy session fence;
# cutover repeats their verification inside the ownership transaction.
class Provider::AccountData::MigrationPreparation
  class Conflict < StandardError; end

  FORMAT = "provider-migration-preparation/v2".freeze
  ACCOUNT_FORMAT = "provider-account-preparation/v2".freeze
  PHASES = %w[inventory capture_auxiliary identities install_inputs verify_copy verify_identities verify_inputs journal_cached_changes awaiting_acceptance].freeze
  INPUT_PROVIDER_KEYS = %w[akahu binance brex coinbase coinstats enable_banking ibkr indexa_capital kraken lunchflow mercury
    monobank onchain_wallet plaid questrade redbark simplefin snaptrade sophtron trade_republic trading212 up wise].freeze
  MAX_STATE_BYTES = 1024 * 1024
  EMPTY_DIGEST = Digest::SHA256.hexdigest(FORMAT).freeze
  Result = Data.define(:phase, :control_id, :run_id, :inventory_count, :linked_count, :unlinked_count, :verified_identities_count,
    :input_integration, :installed_inputs_count, :verified_inputs_count, :unresolved_inputs_count) do
    def awaiting_acceptance?
      phase == "awaiting_acceptance"
    end
  end

  def initialize(provider_key:, legacy_item_id:, family:, page_size: 100)
    unless family.is_a?(Family) && family.persisted? && page_size.is_a?(Integer) && (1..500).cover?(page_size)
      raise ArgumentError, "Preparation requires a persisted authorized family and a bounded page size"
    end
    @manifest = Provider::AccountData::MigrationManifest.for(provider_key)
    @legacy_item_id, @family_id, @page_size = legacy_item_id, family.id, page_size
  end

  def run
    with_admission do
      if control.nil? || read_document(control, :preparation_state).empty?
        reject_orphaned_progress!
        @control = copier.run_quiesced unless verified_copy?
        next result(phase: "copy") unless verified_copy?
        page = copier.verify_retained_quiesced_page(family: family, limit: @page_size)
        initialize_progress(page.context)
        capture_inventory(page)
      else
        load_progress!
        case state.fetch("phase")
        when "inventory" then capture_inventory(read_page(cursor: state["cursor"]))
        when "capture_auxiliary" then capture_auxiliary
        when "identities" then publish_identity_page
        when "install_inputs" then install_input
        when "verify_copy" then verify_inventory(read_page(cursor: state["cursor"]))
        when "verify_identities" then verify_identity_page
        when "verify_inputs"
          auxiliary_inputs? && !state.dig("auxiliary_verification", "complete") ? verify_auxiliary : verify_input
        when "journal_cached_changes" then record_cached_changes
        # A repeated terminal call reports the previous bounded sweeps. It does
        # not issue a new verification claim for accounts changed since then.
        when "awaiting_acceptance" then nil
        end
      end
      result
    end
  rescue StandardError => error
    capture_failure(error)
    raise
  end

  # Repeat the final sweeps without replacing the original inventory, copy run,
  # archive or permanent financial identity evidence.
  def restart_verification!
    with_admission do
      raise Conflict, "Preparation has no retained inventory" unless control
      load_progress!
      unless %w[verify_copy verify_identities verify_inputs journal_cached_changes awaiting_acceptance].include?(state.fetch("phase"))
        raise Conflict, "Finish initial inventory and identity publication before reverification"
      end
      if cached_changes? && state.dig("cached_changes", "phase") == "capture"
        raise Conflict, "Finish recording the original cached observations before restarting preparation verification"
      end
      read_page # Fresh source/context admission before changing any progress.
      begin_verification
      save_progress!
      result
    end
  rescue StandardError => error
    capture_failure(error)
    raise
  end

  # The cutover command already owns the exclusive session permit, financial
  # row locks and final transaction. Reuse the original receipt validators and
  # sweep every copy/identity page again before that transaction changes ownership.
  # Blob bytes were read under the same permit before opening this transaction.
  def verify_for_cutover!(auxiliary_context:)
    unless Provider::AccountData::MigrationCutover::HISTORY_VERIFIERS.key?(manifest.provider_key) &&
        ApplicationRecord.connection.open_transactions.positive?
      raise Conflict, "Cutover verification requires a reviewed provider activation transaction"
    end
    @family = Family.find(@family_id)
    item = manifest.item_type.constantize.find_by!(id: @legacy_item_id, family_id: @family_id)
    Fence.assert_exclusive!(item)
    EnableBankingItem::Lifecycle.assert_copyable!(item)
    @control = ProviderMigrationControl.lock.find_by!(legacy_type: manifest.item_type, legacy_id: item.id, family_id: @family_id)
    load_progress!
    unless state["phase"] == "awaiting_acceptance" && state["requires_cutover_reverification"] == true &&
        state.dig("auxiliary_verification", "complete") == true &&
        state.dig("auxiliary_verification", "context") == auxiliary_context
      raise Conflict, "Cutover requires the original completed preparation and auxiliary capture"
    end
    auxiliary_copier.verify_retained_context!(family: family, expected_context: auxiliary_context)
    retained_auxiliary = state.fetch("auxiliary_verification").deep_dup
    begin_verification
    save_progress!
    loop do
      case state.fetch("phase")
      when "verify_copy" then verify_inventory(read_page(cursor: state["cursor"]))
      when "verify_identities" then verify_identity_page
      when "verify_inputs"
        state["auxiliary_verification"] = retained_auxiliary.merge("verification_run_id" => state.fetch("verification_run_id"))
        state.merge!("input_verification_count" => 1, "verified_inputs_count" => 1)
        validate_auxiliary_verification!
        finish_verification
        save_progress!
      when "awaiting_acceptance" then break
      else raise Conflict, "Unexpected cutover verification phase"
      end
    end
    result
  end

  private
    Fence = Provider::AccountData::LegacyWriterFence
    Value = Provider::AccountData::MigrationValue
    attr_reader :manifest, :control, :state, :family

    def copier
      Provider::AccountData::MigrationCopier.new(provider_key: manifest.provider_key, legacy_item_id: @legacy_item_id, batch_size: @page_size)
    end

    def with_admission
      unless ApplicationRecord.connection.open_transactions.zero?
        raise ArgumentError, "Preparation must enter its legacy fence before any database transaction"
      end
      raise Conflict, "Configure encryption before migration preparation" unless ActiveRecordEncryptionConfig.ready?
      @family = Family.find(@family_id)
      item = manifest.item_type.constantize.find_by!(id: @legacy_item_id, family_id: @family_id)
      Fence.with_exclusive(item) do
        ProviderCredentialClaim.assert_settled_for!(item)
        QuestradeAccount::ActivitiesRequest.assert_settled_for!(item)
        Provider::AccountData::Questrade::RetainedCredentials.assert_copyable!(item)
        EnableBankingItem::Lifecycle.assert_copyable!(item)
        ApplicationRecord.uncached do
          @state, @persisted_state = nil, nil
          @control = ProviderMigrationControl.find_by(legacy_type: manifest.item_type, legacy_id: item.id)
          if control && (control.family_id != @family_id || control.provider_key != manifest.provider_key)
            raise Conflict, "Preparation source ownership changed"
          end
          yield
        end
      end
    rescue ActiveRecord::RecordNotFound
      raise Conflict, "Preparation ownership is missing or changed", cause: nil
    end

    def verified_copy?
      control&.quiescing? && control.high_water_mark["mode"] == "quiesced" && control.high_water_mark["phase"] == "verified"
    end

    def reject_orphaned_progress!
      return unless control
      # Nullable storage distinguishes a new coordinator from lost parent
      # progress. Do not silently adopt account receipts from an unknown run.
      if control.provider_migration_mappings.where.not(preparation_state: nil).exists?
        raise Conflict, "Account preparation receipts require their original connection progress"
      end
      # A zero-account connection has no mapping receipt to reveal a lost
      # parent. Do not adopt a standalone or orphaned auxiliary archive into a
      # new preparation run; its original parent requires explicit recovery.
      if auxiliary_inputs? && (ProviderSyncCheckpoint.where(provider_connection_id: control.provider_connection_id,
          stream: auxiliary_stream).exists? ||
          IngestionBatch.where(provider_connection_id: control.provider_connection_id, stream: auxiliary_stream).exists?)
        raise Conflict, "Connection auxiliary evidence requires its original preparation progress"
      end
      if cached_changes? && (ProviderSyncCheckpoint.where(provider_connection_id: control.provider_connection_id, stream: cached_change_journal_class::STREAM).exists? ||
          IngestionBatch.where(provider_connection_id: control.provider_connection_id, stream: cached_change_journal_class::STREAM).exists?)
        raise Conflict, "Cached-change evidence requires its original preparation progress"
      end
    end

    def initialize_progress(context)
      @persisted_state = {}
      @state = {
        "format" => FORMAT, "run_id" => SecureRandom.uuid, "context" => context.deep_dup,
        "page_size" => @page_size, "phase" => "inventory", "cursor" => nil, "after_legacy_id" => nil,
        "inventory_count" => 0, "linked_count" => 0, "unlinked_count" => 0, "identities_count" => 0,
        "inventory_digest" => EMPTY_DIGEST, "verification_run_id" => nil, "verification_digest" => EMPTY_DIGEST,
        "verification_count" => 0, "verified_identities_count" => 0,
        "input_contract" => input_contract, "input_dispositions_count" => 0, "installed_inputs_count" => 0,
        "unresolved_inputs_count" => 0, "input_verification_count" => 0, "verified_inputs_count" => 0,
        "auxiliary_input" => nil, "auxiliary_verification" => nil
      }
    end

    def load_progress!
      @persisted_state = read_document(control, :preparation_state).deep_dup
      @state = @persisted_state.deep_dup
      unless state.is_a?(Hash) && state["format"] == FORMAT && uuid?(state["run_id"]) && PHASES.include?(state["phase"]) &&
          state["page_size"] == @page_size && state["context"].is_a?(Hash) &&
          (state["cursor"].nil? || state["cursor"].is_a?(Hash)) && (state["after_legacy_id"].nil? || uuid?(state["after_legacy_id"])) &&
          %w[inventory_count linked_count unlinked_count identities_count verification_count verified_identities_count
            input_dispositions_count installed_inputs_count unresolved_inputs_count input_verification_count verified_inputs_count].all? { |key| state[key].is_a?(Integer) && state[key] >= 0 } &&
          %w[inventory_digest verification_digest].all? { |key| digest?(state[key]) } &&
          state["linked_count"] + state["unlinked_count"] == state["inventory_count"] &&
          state["identities_count"] <= state["linked_count"] && state["verified_identities_count"] <= state["linked_count"] &&
          state["verification_count"] <= state["inventory_count"] &&
          (state["verification_run_id"].nil? || uuid?(state["verification_run_id"])) && state["input_contract"] == input_contract &&
          state["installed_inputs_count"] + state["unresolved_inputs_count"] == state["input_dispositions_count"] &&
          state["input_dispositions_count"] <= expected_input_scopes &&
          state["input_verification_count"] <= state["input_dispositions_count"] && state["verified_inputs_count"] <= state["installed_inputs_count"]
        raise Conflict, "Preparation has invalid progress or a changed page size"
      end
      if %w[verify_copy verify_identities verify_inputs journal_cached_changes awaiting_acceptance].include?(state["phase"]) &&
          (!uuid?(state["verification_run_id"]) || state["identities_count"] != state["linked_count"])
        raise Conflict, "Preparation verification has no completed identity inventory"
      end
      if %w[verify_copy verify_identities verify_inputs journal_cached_changes awaiting_acceptance].include?(state["phase"]) && handled_inputs? &&
          state["input_dispositions_count"] != expected_input_scopes
        raise Conflict, "Preparation verification has no complete input disposition inventory"
      end
      validate_input_progress!
      validate_cached_change_progress!
      verify_original_copy!
    end

    def verify_original_copy!
      context = state.fetch("context")
      connection = control.provider_connection
      unless verified_copy? && control.copy_version == Provider::AccountData::MigrationManifest::VERSION &&
          context.values_at("control_id", "family_id", "provider_key", "legacy_id", "connection_id", "copy_run_id", "page_size") ==
            [ control.id, @family_id, manifest.provider_key, @legacy_item_id, control.provider_connection_id, control.high_water_mark["copy_run_id"], @page_size ] &&
          control.audit_results["copy_run_id"] == context["copy_run_id"] && control.audit_results["copy_mode"] == "quiesced" &&
          control.audit_results["declared_writer_fence_held"] == true && control.writer_epoch.zero? &&
          control.lease_owner.nil? && connection&.disabled? && connection.writer_epoch.zero? && connection.lease_owner.nil? &&
          connection.credential_state.blank? && connection.credential_revision == context["credential_revision"] &&
          connection.region == context["region"] && connection.environment == context["environment"]
        raise Conflict, "Preparation lost its original disabled quiesced copy"
      end
      Provider::AccountData::RetainedAccountIndex.assert_complete_for!(control)
    end

    def read_page(cursor: nil, limit: @page_size)
      page = copier.verify_retained_quiesced_page(family: family, cursor: cursor, limit: limit)
      unless page.context == state.fetch("context").merge("page_size" => limit)
        raise Conflict, "Preparation source inventory or copy context changed"
      end
      page
    end

    def capture_inventory(page)
      updates = page.rows.map do |row|
        mapping = mapping_for(row)
        raise Conflict, "Preparation inventory revisited an existing receipt" unless read_document(mapping, :preparation_state).empty?
        disposition = row.fetch("disposition")
        raise Conflict, "Unknown preparation disposition" unless %w[linked unlinked].include?(disposition)
        state["inventory_count"] += 1
        state["#{disposition}_count"] += 1
        state["inventory_digest"] = roll_digest(state.fetch("inventory_digest"), row)
        account_state = { "format" => ACCOUNT_FORMAT, "run_id" => state.fetch("run_id"), "row" => row.deep_dup,
          "identity" => nil, "input" => nil, "verification_run_id" => nil, "verification_identity" => nil, "verification_input" => nil }
        [ mapping, {}, account_state ]
      end
      state["cursor"] = page.next_cursor&.deep_dup
      if page.complete
        unless state["inventory_count"] == state.fetch("context").fetch("account_count")
          raise Conflict, "Preparation inventory did not cover every source account"
        end
        state["phase"] = auxiliary_inputs? ? "capture_auxiliary" : "identities"
        state["after_legacy_id"] = nil
      end
      save_progress!(updates: updates)
    end

    def mapping_for(row)
      control.provider_migration_mappings.find_by!(id: row.fetch("mapping_id"), family_id: @family_id,
        role: "external_account", legacy_type: manifest.account_type, legacy_id: row.fetch("legacy_id"), external_account_id: row.fetch("external_account_id"))
    end

    def account_progress(mapping, row)
      progress = read_document(mapping, :preparation_state).deep_dup
      unless progress.is_a?(Hash) && progress["format"] == ACCOUNT_FORMAT && progress["run_id"] == state["run_id"] && progress["row"] == row
        raise Conflict, "Retained account disposition, link or copied projection changed"
      end
      progress
    end

    # Revisit the exact next source before every identity page. The coordinator
    # alone constructs this continuation from its committed progress.
    def next_account
      cursor = state.fetch("context").merge("page_size" => 1, "after_id" => state["after_legacy_id"]) if state["after_legacy_id"]
      row = read_page(cursor: cursor, limit: 1).rows.first
      return unless row
      mapping = mapping_for(row)
      [ row, mapping, account_progress(mapping, row) ]
    end

    def publisher(mapping)
      Ingestion::IdentityBootstrap.new(mapping: mapping, family: family, page_size: @page_size)
    end

    def publish_identity_page
      selected = next_account
      unless selected
        raise Conflict, "Linked identity inventory is incomplete" unless state["identities_count"] == state["linked_count"]
        if account_inputs?
          state.merge!("phase" => "install_inputs", "after_legacy_id" => nil)
        else
          begin_verification
        end
        save_progress!
        return
      end
      row, mapping, prior = selected
      progress = prior.deep_dup
      if row.fetch("disposition") == "unlinked"
        verify_unlinked!(mapping)
        state["after_legacy_id"] = row.fetch("legacy_id")
      else
        if Provider::AccountData::MigrationSourceSelection.supports?(manifest.provider_key)
          Provider::AccountData::MigrationSourceSelection.ensure!(mapping: mapping, family: family)
        end
        verify_resume_receipt!(mapping, prior["identity"]) if prior["identity"]
        completed = publisher(mapping).run
        progress["identity"] = identity_receipt(completed)
        if completed.verified?
          state["identities_count"] += 1
          state["after_legacy_id"] = row.fetch("legacy_id")
        end
      end
      save_progress!(updates: [ [ mapping, prior, progress ] ])
    end

    def begin_verification
      state.merge!("phase" => "verify_copy", "cursor" => nil, "after_legacy_id" => nil,
        "verification_run_id" => SecureRandom.uuid, "verification_count" => 0, "verification_digest" => EMPTY_DIGEST,
        "verified_identities_count" => 0, "input_verification_count" => 0, "verified_inputs_count" => 0,
        "auxiliary_verification" => nil)
      state.except!("verified_at", "requires_cutover_reverification")
    end

    # This catalog describes implemented handoffs, not all requirements for
    # activation. A missing handler is explicitly unintegrated, never a no-op
    # success. Adding a provider requires reviewing its disposition here too.
    def input_contract
      unless Provider::AccountData::MigrationManifest.all.map(&:provider_key).sort == INPUT_PROVIDER_KEYS.sort
        raise Conflict, "Provider input handoff catalog requires review"
      end
      handled = []
      handled << "binance_history/v1" if account_inputs?
      handled << auxiliary_kind if auxiliary_inputs?
      contract = { "version" => 1, "provider_key" => manifest.provider_key,
        "integration" => handled_inputs? ? "partial" : "not_integrated",
        "handled_inputs" => handled,
        "upstream_history_complete" => false }
      contract["observation_journals"] = [ cached_change_journal_class::FORMAT ] if cached_changes?
      contract
    end

    def handled_inputs?
      account_inputs? || auxiliary_inputs?
    end

    def account_inputs?
      manifest.provider_key == "binance"
    end

    def auxiliary_inputs?
      Provider::AccountData::AuxiliaryCopier.supports?(manifest.provider_key)
    end

    def auxiliary_kind
      manifest.provider_key == "ibkr" ? "ibkr_auxiliary/v1" : "provider_logo/v1"
    end

    def auxiliary_stream
      Provider::AccountData::AuxiliaryCopier.stream_for(manifest.provider_key)
    end

    def expected_input_scopes
      (auxiliary_inputs? ? 1 : 0) + (account_inputs? ? state.fetch("inventory_count") : 0)
    end

    def validate_input_progress!
      input_counts = state.values_at("input_dispositions_count", "installed_inputs_count", "unresolved_inputs_count",
        "input_verification_count", "verified_inputs_count")
      if !handled_inputs? && (input_counts.any?(&:positive?) || %w[capture_auxiliary install_inputs verify_inputs].include?(state["phase"]))
        raise Conflict, "Provider input preparation is not integrated"
      end
      if state["phase"] == "install_inputs" && (!account_inputs? || state["identities_count"] != state["linked_count"])
        raise Conflict, "Provider input installation requires completed financial identities"
      end
      if state["phase"] == "capture_auxiliary" && !auxiliary_inputs?
        raise Conflict, "Provider has no auxiliary capture handler"
      end
      if %w[verify_inputs journal_cached_changes awaiting_acceptance].include?(state["phase"]) &&
          (state["verified_identities_count"] != state["linked_count"] || state["verification_count"] != state["inventory_count"] ||
            state["verification_digest"] != state["inventory_digest"])
        raise Conflict, "Provider input verification requires a completed fresh identity sweep"
      end
      if state["phase"] == "awaiting_acceptance" && handled_inputs? &&
          (state["input_verification_count"] != expected_input_scopes || state["verified_inputs_count"] != state["installed_inputs_count"])
        raise Conflict, "Preparation has no completed provider input sweep"
      end
      unless auxiliary_inputs?
        if state["auxiliary_input"] || state["auxiliary_verification"]
          raise Conflict, "Provider has unexpected auxiliary progress"
        end
        return
      end
      receipt = state["auxiliary_input"]
      validate_auxiliary_receipt!(receipt) if receipt
      if %w[inventory capture_auxiliary].include?(state["phase"])
        unless input_counts.all?(&:zero?) && (receipt.nil? || receipt["phase"] != "complete") && state["auxiliary_verification"].nil?
          raise Conflict, "Auxiliary capture has inconsistent progress"
        end
      elsif receipt.nil? || receipt["phase"] != "complete" || state["input_dispositions_count"] < 1 || state["installed_inputs_count"] < 1 ||
          ((!account_inputs? || state["phase"] == "identities") &&
            (state["input_dispositions_count"] != 1 || state["installed_inputs_count"] != 1 || !state["unresolved_inputs_count"].zero?))
        raise Conflict, "Preparation lost its completed connection auxiliary receipt"
      end
      if state["auxiliary_verification"]
        unless %w[verify_inputs journal_cached_changes awaiting_acceptance].include?(state["phase"])
          raise Conflict, "Connection auxiliary verification is outside its final sweep"
        end
        validate_auxiliary_verification!
      elsif state["phase"] == "awaiting_acceptance" || !state["input_verification_count"].zero? || !state["verified_inputs_count"].zero?
        raise Conflict, "Preparation lost its connection auxiliary verification receipt"
      end
    end

    def auxiliary_copier
      Provider::AccountData::AuxiliaryCopier.for(control: control, chunks_per_run: auxiliary_page_limit)
    end

    def auxiliary_page_limit
      [ @page_size, 8 ].min
    end

    def capture_auxiliary
      prior = state["auxiliary_input"]
      verify_auxiliary_checkpoint_progress!(prior) if prior
      completed = auxiliary_copier.run_retained(family: family, expected_context: prior&.fetch("context"))
      receipt = { "kind" => auxiliary_kind, "phase" => completed.phase, "checkpoint_id" => completed.checkpoint_id,
        "context" => completed.context.deep_dup, "copied_chunks" => completed.copied_chunks, "verified_chunks" => completed.verified_chunks }
      validate_auxiliary_receipt!(receipt)
      if prior && (receipt["context"] != prior["context"] || receipt["checkpoint_id"] != prior["checkpoint_id"] ||
          %w[copy verify complete].index(receipt["phase"]) < %w[copy verify complete].index(prior["phase"]) ||
          receipt["copied_chunks"] < prior["copied_chunks"] || receipt["verified_chunks"] < prior["verified_chunks"])
        raise Conflict, "Connection auxiliary checkpoint regressed or changed its retained identity"
      end
      state["auxiliary_input"] = receipt
      if completed.complete?
        state.merge!("phase" => "identities", "after_legacy_id" => nil, "input_dispositions_count" => 1, "installed_inputs_count" => 1)
      end
      save_progress!
    end

    def verify_auxiliary_checkpoint_progress!(prior)
      scope = ProviderSyncCheckpoint.where(id: prior.fetch("checkpoint_id"), family_id: @family_id,
        provider_connection_id: control.provider_connection_id, stream: auxiliary_stream)
      checkpoint = scope.where("octet_length(state) <= ?", Provider::AccountData::AuxiliaryCopier::MAX_STATE_BYTES * 2).first!
      current = read_document(checkpoint, :state, limit: Provider::AccountData::AuxiliaryCopier::MAX_STATE_BYTES)
      phases = %w[copy verify complete]
      unless phases.include?(current["phase"]) && phases.index(current["phase"]) >= phases.index(prior.fetch("phase")) &&
          %w[copied_chunks verified_chunks].all? { |key| current[key].is_a?(Integer) && current[key] >= prior.fetch(key) }
        raise Conflict, "Connection auxiliary checkpoint regressed behind its preparation receipt"
      end
    end

    def validate_auxiliary_receipt!(receipt)
      context = receipt["context"] if receipt.is_a?(Hash)
      unless receipt.is_a?(Hash) && receipt.keys.sort == %w[checkpoint_id context copied_chunks kind phase verified_chunks] &&
          receipt["kind"] == auxiliary_kind && %w[copy verify complete].include?(receipt["phase"]) && uuid?(receipt["checkpoint_id"]) &&
          context.is_a?(Hash) && context["format"] == auxiliary_copier.class::RETAINED_FORMAT &&
          context["checkpoint_id"] == receipt["checkpoint_id"] && context["copy"] == state.fetch("context").except("page_size") &&
          context["requires_cutover_reverification"] == true && digest?(context["source_digest"]) &&
          context["chunks"].is_a?(Integer) && context["chunks"] >= 0 && context["chunk_bytes"].is_a?(Integer) &&
          (1024..1024 * 1024).cover?(context["chunk_bytes"]) && context["chunks"] <= Provider::AccountData::AuxiliaryCopier::MAX_BYTES.div(context["chunk_bytes"]) + 1 &&
          %w[copied_chunks verified_chunks].all? { |key| receipt[key].is_a?(Integer) && (0..context["chunks"]).cover?(receipt[key]) } &&
          receipt["verified_chunks"] <= receipt["copied_chunks"] &&
          (receipt["phase"] != "copy" || receipt["verified_chunks"].zero?) &&
          (receipt["phase"] == "copy" || receipt["copied_chunks"] == context["chunks"]) &&
          (receipt["phase"] != "complete" || receipt["verified_chunks"] == context["chunks"])
        raise Conflict, "Connection auxiliary receipt has invalid retained progress"
      end
    end

    def validate_auxiliary_verification!
      progress = state.fetch("auxiliary_verification")
      context = progress["context"] if progress.is_a?(Hash)
      receipt = state.fetch("auxiliary_input")
      unless progress.is_a?(Hash) && progress.keys.sort == %w[complete context cursor digest verification_run_id verified_chunks] &&
          progress["verification_run_id"] == state["verification_run_id"] && uuid?(progress["verification_run_id"]) &&
          context.is_a?(Hash) && context.except("content_sha256", "target_attachment", "limit") == receipt.fetch("context") &&
          digest?(context["content_sha256"]) && context.key?("target_attachment") && context["limit"] == auxiliary_page_limit &&
          progress["verified_chunks"].is_a?(Integer) && (0..context["chunks"]).cover?(progress["verified_chunks"]) && digest?(progress["digest"]) &&
          [ true, false ].include?(progress["complete"]) && progress["complete"] == (progress["verified_chunks"] == context["chunks"]) &&
          progress["cursor"] == (progress["complete"] ? nil : context.merge("next_chunk" => progress["verified_chunks"])) &&
          (progress["complete"] ?
            (state["input_verification_count"] >= 1 && state["verified_inputs_count"] >= 1 &&
              (account_inputs? || (state["input_verification_count"] == 1 && state["verified_inputs_count"] == 1))) :
            (state["input_verification_count"].zero? && state["verified_inputs_count"].zero?))
        raise Conflict, "Connection auxiliary verification continuation changed"
      end
    end

    # Remote blob reads belong to the child outside row transactions. Only the
    # parent page receipt advances here; the original child checkpoint is never
    # restarted, replaced or rewritten during a fresh final sweep.
    def verify_auxiliary
      prior = state["auxiliary_verification"]
      page = auxiliary_copier.verify_retained_page(family: family, cursor: prior&.fetch("cursor"), limit: auxiliary_page_limit)
      unless page.context.except("content_sha256", "target_attachment", "limit") == state.fetch("auxiliary_input").fetch("context") &&
          (prior.nil? || page.context == prior.fetch("context"))
        raise Conflict, "Connection auxiliary verification lost its original capture"
      end
      count, digest = prior ? prior.values_at("verified_chunks", "digest") : [ 0, EMPTY_DIGEST ]
      page.rows.each do |row|
        unless row["index"] == count && row["byte_size"].is_a?(Integer) && (1..page.context.fetch("chunk_bytes")).cover?(row["byte_size"]) && digest?(row["sha256"])
          raise Conflict, "Connection auxiliary verification skipped or changed a chunk"
        end
        count += 1
        digest = roll_digest(digest, row)
      end
      state["auxiliary_verification"] = { "verification_run_id" => state.fetch("verification_run_id"), "context" => page.context.deep_dup,
        "cursor" => page.next_cursor&.deep_dup, "verified_chunks" => count, "digest" => digest, "complete" => page.complete }
      if page.complete
        state.merge!("input_verification_count" => 1, "verified_inputs_count" => 1)
      end
      validate_auxiliary_verification!
      finish_verification if page.complete && !account_inputs?
      save_progress!
    end

    def input_disposition(row, mapping)
      return "unlinked_retained" if row.fetch("disposition") == "unlinked"
      external = mapping.external_account.reload
      return "unsupported_topology" unless state.fetch("inventory_count") == 1 && external.external_id == "combined" && external.identity_namespace == "connection"
      "installed"
    end

    def install_input
      selected = next_account
      unless selected
        raise Conflict, "Provider input dispositions are incomplete" unless state["input_dispositions_count"] == expected_input_scopes
        begin_verification
        save_progress!
        return
      end
      row, mapping, prior = selected
      raise Conflict, "Provider input installation revisited a committed disposition" if prior["input"]
      disposition = input_disposition(row, mapping)
      receipt = { "kind" => "binance_history/v1", "status" => disposition }
      if disposition == "installed"
        verify_identity_receipt!(mapping, prior.fetch("identity"))
        installed = input_publisher(mapping).install
        checkpoint = ProviderSyncCheckpoint.find(installed.checkpoint_id)
        checkpoint_state = read_document(checkpoint, :state, limit: Provider::AccountData::Binance::HistoryBootstrap::MAX_CHECKPOINT_BYTES)
        receipt.merge!("checkpoint_id" => installed.checkpoint_id, "batch_id" => installed.batch_id,
          "receipt_digest" => checkpoint_state.fetch("receipt_digest"))
        state["installed_inputs_count"] += 1
      else
        state["unresolved_inputs_count"] += 1
      end
      verify_input_receipt!(mapping, receipt, row: row)
      state["input_dispositions_count"] += 1
      state["after_legacy_id"] = row.fetch("legacy_id")
      save_progress!(updates: [ [ mapping, prior, prior.merge("input" => receipt) ] ])
    end

    def input_publisher(mapping)
      Provider::AccountData::Binance::HistoryBootstrap.new(mapping: mapping, family: family)
    end

    def verify_input_receipt!(mapping, receipt, row:)
      expected = input_disposition(row, mapping)
      unless receipt.is_a?(Hash) && receipt["kind"] == "binance_history/v1" && receipt["status"] == expected
        raise Conflict, "Provider input disposition changed or is missing"
      end
      stream = Provider::AccountData::Binance::HistoryBootstrap::STREAM
      checkpoints = ProviderSyncCheckpoint.where(provider_connection_id: control.provider_connection_id,
        external_account_id: mapping.external_account_id, stream: stream)
      if expected != "installed"
        unless receipt.keys.sort == %w[kind status] && checkpoints.none? &&
            IngestionBatch.where(provider_connection_id: control.provider_connection_id, external_account_id: mapping.external_account_id, stream: stream).none?
          raise Conflict, "An unresolved provider input acquired installation evidence"
        end
        verify_unlinked!(mapping) if expected == "unlinked_retained"
        return
      end
      unless receipt.keys.sort == %w[batch_id checkpoint_id kind receipt_digest status] &&
          uuid?(receipt["checkpoint_id"]) && uuid?(receipt["batch_id"]) && digest?(receipt["receipt_digest"])
        raise Conflict, "Provider input receipt has invalid installation identifiers"
      end
      checkpoint = checkpoints.find_by!(id: receipt.fetch("checkpoint_id"), family_id: @family_id)
      current = read_document(checkpoint, :state, limit: Provider::AccountData::Binance::HistoryBootstrap::MAX_CHECKPOINT_BYTES)
      unless checkpoint.ingestion_batch_id == receipt["batch_id"] && current["receipt_digest"] == receipt["receipt_digest"]
        raise Conflict, "Provider input lost its original installed checkpoint"
      end
      document = Provider::AccountData::Binance::HistoryBootstrap.read_receipt!(checkpoint, connection: control.provider_connection)
      context = document.fetch("plan").fetch("context")
      unless context["migration_mapping_id"] == mapping.id && context["migration_control_id"] == control.id &&
          context["copy_run_id"] == state.fetch("context").fetch("copy_run_id")
        raise Conflict, "Provider input receipt belongs to a different retained copy"
      end
    end

    def verify_input
      selected = next_account
      unless selected
        unless state["input_verification_count"] == state["input_dispositions_count"] && state["verified_inputs_count"] == state["installed_inputs_count"]
          raise Conflict, "Final provider input sweep is incomplete"
        end
        finish_verification
        save_progress!
        return
      end
      row, mapping, prior = selected
      unless prior["verification_run_id"] == state["verification_run_id"] && prior["verification_input"].nil?
        raise Conflict, "Provider input has not joined this verification sweep"
      end
      receipt = prior.fetch("input")
      verify_input_receipt!(mapping, receipt, row: row)
      if receipt.fetch("status") == "installed"
        verify_completed_identity_receipt!(mapping, prior.fetch("verification_identity"))
        input_publisher(mapping).verify!(checkpoint_id: receipt.fetch("checkpoint_id"),
          batch_id: receipt.fetch("batch_id"), receipt_digest: receipt.fetch("receipt_digest"))
        state["verified_inputs_count"] += 1
      end
      state["input_verification_count"] += 1
      state["after_legacy_id"] = row.fetch("legacy_id")
      progress = prior.merge("verification_input" => { "verification_run_id" => state.fetch("verification_run_id"), "input" => receipt.deep_dup })
      save_progress!(updates: [ [ mapping, prior, progress ] ])
    end

    def finish_verification
      if cached_changes?
        state["phase"] = "journal_cached_changes"
      else
        state.merge!("phase" => "awaiting_acceptance", "verified_at" => Time.current.utc.iso8601(6), "requires_cutover_reverification" => true)
      end
    end

    def cached_changes?
      manifest.provider_key == "plaid"
    end

    def cached_change_journal_class
      Provider::AccountData::Plaid::CachedChangeJournal
    end

    def validate_cached_change_progress!
      receipt = state["cached_changes"]
      unless cached_changes?
        raise Conflict, "Unexpected cached-change preparation evidence" if receipt || state["cached_change_verification_run_id"] || state["phase"] == "journal_cached_changes"
        return
      end
      if receipt
        unless receipt.is_a?(Hash) && receipt.keys.sort == %w[batch_id blockers captured_pages checkpoint_id context observations phase verified_pages] &&
            %w[capture verify recorded].include?(receipt["phase"]) && uuid?(receipt["checkpoint_id"]) && uuid?(receipt["batch_id"]) &&
            receipt["context"].is_a?(Hash) && receipt["context"]["copy"] == state.fetch("context").merge("page_size" => 1) &&
            receipt["context"]["page_size"] == @page_size &&
            %w[captured_pages verified_pages observations blockers].all? { |key| receipt[key].is_a?(Integer) && receipt[key] >= 0 } &&
            receipt["captured_pages"].positive? && receipt["verified_pages"] <= receipt["captured_pages"] &&
            (receipt["phase"] != "recorded" || receipt["verified_pages"] == receipt["captured_pages"]) &&
            uuid?(state["cached_change_verification_run_id"])
          raise Conflict, "Cached-change preparation receipt changed its original context"
        end
        checkpoint = ProviderSyncCheckpoint.find_by!(id: receipt.fetch("checkpoint_id"), family_id: @family_id,
          provider_connection_id: control.provider_connection_id, stream: cached_change_journal_class::STREAM, scope_key: "connection")
        current = read_document(checkpoint, :state, limit: cached_change_journal_class::MAX_STATE_BYTES)
        unless current["format"] == cached_change_journal_class::FORMAT && current["checkpoint_id"] == checkpoint.id &&
            current["context"] == receipt["context"] && current["captured_pages"] == receipt["captured_pages"] &&
            current["observations"] == receipt["observations"] && current["blockers"] == receipt["blockers"] &&
            checkpoint.ingestion_batch_id == receipt["batch_id"]
          # During capture a child may commit its next page before the parent's
          # receipt. The unchanged retained prefix identifies that exact child.
          unless current["format"] == cached_change_journal_class::FORMAT && current["checkpoint_id"] == checkpoint.id &&
              current["context"] == receipt["context"] && current["captured_pages"].is_a?(Integer) && current["captured_pages"] > receipt["captured_pages"] &&
              current["observations"].is_a?(Integer) && current["observations"] >= receipt["observations"] &&
              current["blockers"].is_a?(Integer) && current["blockers"] >= receipt["blockers"] && receipt["phase"] == "capture" &&
              IngestionBatch.where(id: receipt["batch_id"], family_id: @family_id, provider_connection_id: control.provider_connection_id,
                stream: cached_change_journal_class::STREAM, sequence: receipt["captured_pages"] - 1).exists?
            raise Conflict, "Cached-change child lost its original committed progress"
          end
        end
      elsif state["cached_change_verification_run_id"]
        raise Conflict, "Cached-change preparation lost its receipt"
      end
      if state["phase"] == "awaiting_acceptance" &&
          (!receipt || receipt["phase"] != "recorded" || state["cached_change_verification_run_id"] != state["verification_run_id"])
        raise Conflict, "Plaid preparation has no completed cached-observation sweep"
      end
      if state["phase"] == "awaiting_acceptance"
        unless current["phase"] == "recorded" && current["verified_pages"] == receipt["verified_pages"]
          raise Conflict, "Plaid preparation lost its completed child sweep"
        end
        # Validate the retained checkpoint header/signature before reporting its
        # earlier enumeration. This remains a retained report, not a new sweep.
        completed = cached_change_journal_class.new(control: control, family: family, page_size: @page_size).run
        unless completed.recorded? && completed.checkpoint_id == receipt["checkpoint_id"] && completed.batch_id == receipt["batch_id"] &&
            completed.captured_pages == receipt["captured_pages"] && completed.observations == receipt["observations"] && completed.blockers == receipt["blockers"]
          raise Conflict, "Plaid preparation child report differs from its original receipt"
        end
      end
      if state["phase"] == "journal_cached_changes" &&
          (!uuid?(state["verification_run_id"]) || state["verified_identities_count"] != state["linked_count"] ||
            state["verification_count"] != state["inventory_count"] || state["verification_digest"] != state["inventory_digest"] ||
            state["input_verification_count"] != expected_input_scopes || state["verified_inputs_count"] != state["installed_inputs_count"])
        raise Conflict, "Journal publication requires the completed preparation sweeps"
      end
    end

    def record_cached_changes
      journal = cached_change_journal_class.new(control: control, family: family, page_size: @page_size)
      prior = state["cached_changes"]
      completed = if prior && state["cached_change_verification_run_id"] != state["verification_run_id"]
        journal.restart_verification!
      else
        journal.run
      end
      state["cached_changes"] = { "phase" => completed.phase, "checkpoint_id" => completed.checkpoint_id, "batch_id" => completed.batch_id,
        "context" => completed.context.deep_dup, "captured_pages" => completed.captured_pages, "verified_pages" => completed.verified_pages,
        "observations" => completed.observations, "blockers" => completed.blockers }
      state["cached_change_verification_run_id"] = state.fetch("verification_run_id")
      if completed.recorded?
        state.merge!("phase" => "awaiting_acceptance", "verified_at" => Time.current.utc.iso8601(6), "requires_cutover_reverification" => true)
      end
      # Enumeration is separate from installed inputs and never counts as an
      # accepted Plaid cursor, financial replay or complete upstream history.
      save_progress!
    end

    def verify_inventory(page)
      updates = page.rows.map do |row|
        mapping = mapping_for(row)
        prior = account_progress(mapping, row)
        if row.fetch("disposition") == "linked"
          verify_identity_receipt!(mapping, prior.fetch("identity"))
        else
          verify_unlinked!(mapping)
        end
        verify_input_receipt!(mapping, prior.fetch("input"), row: row) if account_inputs?
        progress = prior.merge("verification_run_id" => state.fetch("verification_run_id"), "verification_identity" => nil, "verification_input" => nil)
        state["verification_count"] += 1
        state["verification_digest"] = roll_digest(state.fetch("verification_digest"), row)
        [ mapping, prior, progress ]
      end
      state["cursor"] = page.next_cursor&.deep_dup
      if page.complete
        unless state["verification_count"] == state["inventory_count"] && state["verification_digest"] == state["inventory_digest"]
          raise Conflict, "Final preparation inventory differs from its original source observations"
        end
        state["phase"] = "verify_identities"
        state["after_legacy_id"] = nil
      end
      save_progress!(updates: updates)
    end

    def verify_identity_page
      selected = next_account
      unless selected
        unless state["verified_identities_count"] == state["linked_count"] && state["verification_digest"] == state["inventory_digest"]
          raise Conflict, "Final preparation identity sweep is incomplete"
        end
        if handled_inputs?
          state.merge!("phase" => "verify_inputs", "after_legacy_id" => nil)
        else
          finish_verification
        end
        save_progress!
        return
      end
      row, mapping, prior = selected
      unless prior["verification_run_id"] == state["verification_run_id"]
        raise Conflict, "Account has not joined this retained-copy verification sweep"
      end
      progress = prior.deep_dup
      if row.fetch("disposition") == "unlinked"
        verify_unlinked!(mapping)
        state["after_legacy_id"] = row.fetch("legacy_id")
      elsif prior["verification_identity"].nil?
        verify_identity_receipt!(mapping, prior.fetch("identity"))
        # A crash after the child commits but before save_progress! can repeat
        # this reset. It preserves proof and only restarts this bounded sweep.
        progress["verification_identity"] = identity_receipt(publisher(mapping).restart_verification!)
      else
        verify_resume_receipt!(mapping, prior.fetch("verification_identity"))
        completed = publisher(mapping).run
        progress["verification_identity"] = identity_receipt(completed)
        if completed.verified?
          state["verified_identities_count"] += 1
          state["after_legacy_id"] = row.fetch("legacy_id")
        end
      end
      save_progress!(updates: [ [ mapping, prior, progress ] ])
    end

    def identity_receipt(result)
      { "phase" => result.phase, "checkpoint_id" => result.checkpoint_id, "batch_id" => result.batch_id,
        "captured_entries" => result.captured_entries, "verified_entries" => result.verified_entries }
    end

    def verify_identity_receipt!(mapping, receipt)
      unless receipt.is_a?(Hash) && receipt["phase"] == "verified"
        raise Conflict, "Account has no completed financial identity receipt"
      end
      checkpoint, checkpoint_state = receipt_checkpoint(mapping, receipt)
      # A previously committed restart may legitimately leave phase 'verify'
      # before coordinator progress commits. Full verification is still required.
      unless %w[verify verified].include?(checkpoint_state["phase"]) &&
          checkpoint_state["captured_entries"] == receipt["captured_entries"] && checkpoint.ingestion_batch_id == receipt["batch_id"]
        raise Conflict, "Account financial identity checkpoint changed"
      end
    end

    def verify_resume_receipt!(mapping, receipt)
      _checkpoint, checkpoint_state = receipt_checkpoint(mapping, receipt)
      phases = %w[capture verify verified]
      prior_phase, current_phase = phases.index(receipt["phase"]), phases.index(checkpoint_state["phase"])
      unless prior_phase && current_phase && current_phase >= prior_phase &&
          receipt["captured_entries"].is_a?(Integer) && checkpoint_state["captured_entries"].is_a?(Integer) &&
          checkpoint_state["captured_entries"] >= receipt["captured_entries"]
        raise Conflict, "Account identity checkpoint regressed behind its committed receipt"
      end
      # Child progress can legitimately be ahead after a parent receipt failure;
      # IdentityBootstrap revalidates its full context and committed batch itself.
    end

    def verify_completed_identity_receipt!(mapping, receipt)
      verify_identity_receipt!(mapping, receipt)
      _checkpoint, current = receipt_checkpoint(mapping, receipt)
      unless current["phase"] == "verified" && receipt["verified_entries"].is_a?(Integer) && current["verified_entries"] == receipt["verified_entries"]
        raise Conflict, "Provider input requires the completed current identity receipt"
      end
    end

    def receipt_checkpoint(mapping, receipt)
      unless receipt.is_a?(Hash) && uuid?(receipt["checkpoint_id"])
        raise Conflict, "Account identity receipt has no retained checkpoint"
      end
      checkpoint = ProviderSyncCheckpoint.find_by!(id: receipt.fetch("checkpoint_id"), family_id: @family_id,
        provider_connection_id: control.provider_connection_id, external_account_id: mapping.external_account_id,
        stream: Ingestion::IdentityBootstrap::STREAM, scope_key: "account:#{mapping.external_account_id}")
      checkpoint_state = read_document(checkpoint, :state, limit: Ingestion::IdentityBootstrap::MAX_STATE_BYTES)
      unless checkpoint_state["format"] == Ingestion::IdentityBootstrap::FORMAT
        raise Conflict, "Account identity receipt lost its original checkpoint context"
      end
      [ checkpoint, checkpoint_state ]
    end

    def verify_unlinked!(mapping)
      external_id = mapping.external_account_id
      if AccountProvider.where(external_account_id: external_id).exists? || SourceRecord.where(external_account_id: external_id).exists? ||
          EntrySource.where(bootstrap_external_account_id: external_id).exists? ||
          ProviderSyncCheckpoint.where(provider_connection_id: control.provider_connection_id, external_account_id: external_id,
            stream: Ingestion::IdentityBootstrap::STREAM).exists?
        raise Conflict, "An unlinked source acquired financial ownership or identity evidence"
      end
    end

    def save_progress!(updates: [])
      raise Conflict, "Preparation progress exceeds its state bound" if Value.dump(state).bytesize > MAX_STATE_BYTES
      control.with_lock do
        unless read_document(control, :preparation_state) == @persisted_state
          raise Conflict, "Preparation progress changed during its operation"
        end
        verify_original_copy!
        updates.each do |mapping, expected, replacement|
          mapping.lock!
          unless read_document(mapping, :preparation_state) == expected && mapping.provider_migration_control_id == control.id && mapping.family_id == @family_id &&
              mapping.role == "external_account" && mapping.legacy_type == manifest.account_type &&
              mapping.legacy_id == replacement.fetch("row").fetch("legacy_id") && mapping.external_account_id == replacement.fetch("row").fetch("external_account_id") &&
              mapping.source_checksum == replacement.fetch("row").fetch("source_checksum")
            raise Conflict, "Account preparation ownership or progress changed"
          end
          raise Conflict, "Account preparation receipt exceeds its state bound" if Value.dump(replacement).bytesize > MAX_STATE_BYTES
          mapping.update!(preparation_state: replacement)
        end
        control.update!(preparation_state: state)
      end
      @persisted_state = state.deep_dup
    end

    def read_document(record, attribute, limit: MAX_STATE_BYTES)
      column = record.class.connection.quote_column_name(attribute)
      bytes = record.class.where(id: record.id).pick(Arel.sql("octet_length(#{column})"))
      return {} if bytes.nil?
      raise Conflict, "Preparation document exceeds its stored read bound" if bytes > limit * 2
      document = record.public_send(attribute)
      unless document.is_a?(Hash) && Value.dump(document).bytesize <= limit
        raise Conflict, "Preparation document is invalid or exceeds its decoded bound"
      end
      document
    end

    def roll_digest(previous, row)
      Digest::SHA256.hexdigest(previous + "\0" + Value.dump(row))
    end

    def uuid?(value)
      value.is_a?(String) && value.match?(Fence::UUID)
    end

    def digest?(value)
      value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
    end

    def result(phase: state&.fetch("phase"))
      Result.new(phase: phase.dup.freeze, control_id: control.id, run_id: state&.fetch("run_id"),
        inventory_count: state&.fetch("inventory_count") || 0, linked_count: state&.fetch("linked_count") || 0,
        unlinked_count: state&.fetch("unlinked_count") || 0, verified_identities_count: state&.fetch("verified_identities_count") || 0,
        input_integration: input_contract.fetch("integration"), installed_inputs_count: state&.fetch("installed_inputs_count") || 0,
        verified_inputs_count: state&.fetch("verified_inputs_count") || 0, unresolved_inputs_count: state&.fetch("unresolved_inputs_count") || 0)
    end

    def capture_failure(error)
      return if error.is_a?(Fence::Busy) || error.is_a?(Provider::AccountData::MigrationCopier::Busy)
      DebugLogEntry.capture(category: "provider_migration_error", level: "error", message: "Provider migration preparation requires retry or review",
        source: self.class.name, provider_key: manifest.provider_key, family_id: @family_id,
        metadata: { migration_control_id: control&.id, legacy_item_id: @legacy_item_id, error_class: error.class.name })
    rescue StandardError
      nil
    end
end
