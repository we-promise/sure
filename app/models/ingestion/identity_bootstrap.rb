# Publishes provenance for existing financial UUIDs, never financial values.
# Each call holds the declared legacy permit through one atomic bounded page.
class Ingestion::IdentityBootstrap
  class Conflict < Ingestion::LegacyIdentityEvidence::InvalidEvidence; end

  FORMAT = "financial-identity-bootstrap-v1".freeze
  STREAM = Ingestion::LegacyIdentityEvidence::STREAM
  MAX_STATE_BYTES = 1024 * 1024
  IDENTITY_FIELDS = %w[entry_id entryable_type kind external_id pending_aliases pending identity_columns match_method identities identity_state].freeze
  Result = Data.define(:phase, :checkpoint_id, :batch_id, :captured_entries, :verified_entries, :replayed) do
    def verified?
      phase == "verified"
    end
  end

  def initialize(mapping:, family:, page_size: 100)
    unless mapping.is_a?(ProviderMigrationMapping) && mapping.persisted? && family.is_a?(Family) && family.persisted? &&
        page_size.is_a?(Integer) && (1..500).cover?(page_size)
      raise ArgumentError, "Identity bootstrap requires a persisted mapping, family and bounded page size"
    end
    @mapping_id, @family_id, @page_size = mapping.id, family.id, page_size
  end

  def run
    with_admission do
      load_checkpoint!
      page, document, payload = prepare_page(cursor: state.fetch("phase") == "verified" ? nil : state["cursor"])
      if state.fetch("phase") == "verified"
        verify_terminal_inventory!
        next result(replayed: true)
      end

      if state.fetch("phase") == "capture"
        fresh_rows = document.fetch("rows").reject { |row| existing_identity?(row) }
        batch = publish(payload, fresh_rows) if fresh_rows.any?
        state["captured_entries"] += fresh_rows.size
        state["phase"] = "verify" if page.complete
      else
        document.fetch("rows").each do |row|
          raise Conflict, "Verification found a financial identity that has not been captured" unless existing_identity?(row)
        end
        state["verified_entries"] += document.fetch("rows").size
        if page.complete
          verify_terminal_inventory!
          state["phase"] = "verified"
          state["verified_at"] = Time.current.utc.iso8601(6)
          state["requires_cutover_reverification"] = true
        end
      end
      state["cursor"] = page.complete ? nil : page.next_cursor
      save_checkpoint!(batch: batch)
      result(replayed: batch.nil?)
    end
  rescue StandardError => error
    capture_failure(error)
    raise
  end

  # A fresh sweep never discards old proof. Capture can revisit committed rows
  # after a late candidate was discovered; only genuinely missing identities add
  # batches. Changed ownership/copy context still requires explicit disposition.
  def restart_capture!
    restart!(phase: "capture")
  end

  def restart_verification!
    restart!(phase: "verify")
  end

  private
    Evidence = Ingestion::LegacyIdentityEvidence
    Value = Provider::AccountData::MigrationValue
    Fence = Provider::AccountData::LegacyWriterFence
    attr_reader :mapping, :control, :connection, :external, :account, :link, :checkpoint, :state

    def with_admission
      raise Conflict, "Configure encryption before publishing identity evidence" unless ActiveRecordEncryptionConfig.ready?
      selected = ProviderMigrationMapping.find_by!(id: @mapping_id, family_id: @family_id)
      selected_control = selected.provider_migration_control
      manifest = Provider::AccountData::MigrationManifest.for(selected_control.provider_key)
      item = manifest.item_type.constantize.find_by!(id: selected_control.legacy_id, family_id: @family_id)
      Fence.with_exclusive(item) do
        ApplicationRecord.uncached do
          ApplicationRecord.transaction do
            @proof_batch = nil
            @control = ProviderMigrationControl.lock.find_by!(id: selected_control.id, family_id: @family_id)
            @connection = ProviderConnection.lock.find_by!(id: control.provider_connection_id, family_id: @family_id)
            @mapping = ProviderMigrationMapping.find_by!(id: @mapping_id, family_id: @family_id, provider_migration_control_id: control.id)
            unless mapping.role == "external_account" && mapping.legacy_type == manifest.account_type
              raise Conflict, "Identity bootstrap requires a mapped legacy external account"
            end
            @external = ExternalAccount.find_by!(id: mapping.external_account_id, provider_connection_id: connection.id, family_id: @family_id)
            @link = AccountProvider.find_by!(external_account_id: external.id, family_id: @family_id)
            planned_link = link.attributes.slice("id", "account_id", "external_account_id", "lock_version")
            @account = Account.lock.find_by!(id: link.account_id, family_id: @family_id)
            external.lock!
            link.lock!
            unless link.attributes.slice(*planned_link.keys) == planned_link && AccountProvider.where(external_account_id: external.id).pick(:id) == link.id
              raise Conflict, "Identity bootstrap link changed while acquiring its lock"
            end
            mapping.lock!
            Evidence.with_validation_cache { yield }
          end
        end
      end
    rescue ActiveRecord::RecordNotFound
      raise Conflict, "Identity bootstrap ownership is missing or changed", cause: nil
    rescue Evidence::InvalidEvidence, Provider::AccountData::IdentityBootstrapPlan::InvalidContext,
        Provider::AccountData::Plaid::IdentityBootstrapPlan::InvalidContext, Provider::AccountData::StaleWriter => error
      raise Conflict, error.message, cause: nil
    end

    def planner
      klass = control.provider_key == "plaid" ? Provider::AccountData::Plaid::IdentityBootstrapPlan : Provider::AccountData::IdentityBootstrapPlan
      klass.new(mapping: mapping, family: account.family)
    end

    def scope_key
      "account:#{external.id}"
    end

    def checkpoint_scope
      ProviderSyncCheckpoint.where(provider_connection: connection, family_id: @family_id, stream: STREAM, scope_key: scope_key)
    end

    def load_checkpoint!(required: false)
      @checkpoint = checkpoint_scope.lock.first
      unless checkpoint
        if required || connection.ingestion_batches.where(stream: STREAM, external_account: external).exists? ||
            EntrySource.where(bootstrap_external_account_id: external.id).exists?
          raise Conflict, "Existing identity evidence requires its original checkpoint"
        end
        @state = { "format" => FORMAT, "phase" => "capture", "page_size" => @page_size,
          "context" => nil, "bindings" => {}, "cursor" => nil, "next_sequence" => 0,
          "captured_entries" => 0, "verified_entries" => 0 }
        return
      end
      stored_bytes = checkpoint_scope.pick(Arel.sql("octet_length(state)"))
      unless stored_bytes && stored_bytes <= MAX_STATE_BYTES * 2 && checkpoint.schema_version == 1 &&
          checkpoint.external_account_id == external.id && checkpoint.provider_authorization_id.nil? &&
          checkpoint.provider_sync_generation_id.nil? && checkpoint.cursor.nil? && checkpoint.covered_through.nil?
        raise Conflict, "Identity checkpoint has unrelated or oversized execution context"
      end
      @state = checkpoint.state.deep_dup
      unless state.is_a?(Hash) && state["format"] == FORMAT && %w[capture verify verified].include?(state["phase"]) &&
          state["page_size"] == @page_size && state["context"].is_a?(Hash) && state["bindings"].is_a?(Hash) &&
          (state["cursor"].nil? || state["cursor"].is_a?(Hash)) &&
          %w[next_sequence captured_entries verified_entries].all? { |key| state[key].is_a?(Integer) && state[key] >= 0 } &&
          (state["phase"] != "capture" || state["verified_entries"].zero?) &&
          (state["phase"] != "verified" || (state["cursor"].nil? && state["verified_at"].present? && state["requires_cutover_reverification"] == true))
        raise Conflict, "Identity checkpoint has invalid progress"
      end
      if checkpoint.ingestion_batch
        payload = Evidence.validate_batch!(checkpoint.ingestion_batch)
        unless payload.fetch("admission")["migration_mapping_id"] == mapping.id &&
            checkpoint.ingestion_batch.sequence == state.fetch("next_sequence") - 1
          raise Conflict, "Identity checkpoint does not retain its last committed page"
        end
      elsif !state.fetch("next_sequence").zero?
        raise Conflict, "Identity checkpoint lost its committed page"
      end
    end

    def prepare_page(cursor:)
      page = planner.page(cursor: cursor, limit: @page_size)
      raise Conflict, "Financial identity planning requires resolution of blocked rows" unless page.ready?
      document = Evidence.normalize_plan(page.document)
      resources = (state.fetch("bindings").keys + document.fetch("rows").map { |row| row.fetch("kind") == "transaction" ? "transactions" : "activities" }).uniq.sort
      bindings = resources.to_h do |resource|
        binding = Provider::AccountData::GenerationAccounts.new(connection, resource: resource, identity_namespace: external.identity_namespace).capture_one(external)
        [ resource, binding ]
      end
      unless state.fetch("bindings").all? { |resource, binding| bindings[resource] == binding }
        raise Conflict, "Identity bootstrap source selection or authorization changed"
      end
      payload = Evidence.seal(plan: document, control: control, mapping: mapping)
      context = document.except("after_entry_id", "last_entry_id", "rows", "blockers", "complete", "page_limit")
        .merge("admission" => payload.fetch("admission").except("captured_at", "resource_bindings"),
          "account_currency" => account.currency, "accountable_type" => account.accountable_type, "accountable_id" => account.accountable_id)
      if state["context"] && state["context"] != context
        raise Conflict, "Identity bootstrap copied source context changed"
      end
      state["context"], state["bindings"] = context, bindings
      [ page, document, payload ]
    end

    def existing_identity?(row)
      ids = row.fetch("identities").map { |identity| identity.fetch("external_id") }
      records = SourceRecord.where(external_account: external, external_id: ids).includes(:entry_sources).to_a
      if records.empty?
        if EntrySource.where(bootstrap_external_account_id: external.id, entry_identity: row.fetch("entry_id")).exists?
          raise Conflict, "Captured financial UUID has changed its source identity"
        end
        return false
      end
      unless records.size == ids.size && records.map(&:external_id).sort == ids.sort
        raise Conflict, "Financial identity has partial or conflicting source evidence"
      end
      records.each do |record|
        mappings = record.entry_sources.to_a
        unless record.kind == row.fetch("kind") && !record.withdrawn? && mappings.one? && mappings.first.active? &&
            mappings.first.entry_id == row.fetch("entry_id") && mappings.first.bootstrap_external_account_id == external.id
          raise Conflict, "Financial identity has orphaned or conflicting posting evidence"
        end
        unless record.ingestion_batch_id == mappings.first.bootstrap_batch_id
          raise Conflict, "Pre-native observation no longer references its original bootstrap batch"
        end
        if @proof_batch&.id != record.ingestion_batch_id
          @proof_batch = IngestionBatch.find_by!(id: record.ingestion_batch_id, family_id: @family_id,
            provider_connection_id: connection.id, external_account_id: external.id)
        end
        record.association(:ingestion_batch).target = @proof_batch
        mappings.first.association(:bootstrap_batch).target = @proof_batch
        original = Evidence.for_mapping!(entry_source: mappings.first, source_record: record).fetch(:row)
        unless original.slice(*IDENTITY_FIELDS) == row.slice(*IDENTITY_FIELDS)
          raise Conflict, "Financial identity changed after its original capture"
        end
        Evidence.for_observation!(source_record: record)
      end
      true
    end

    def publish(payload, rows)
      # The only mutations here are new provenance and the dedicated checkpoint.
      # Existing Entry, Transaction and Trade rows are never saved or rewritten.
      sequence = state.fetch("next_sequence")
      batch = connection.ingestion_batches.create!(family_id: @family_id, external_account: external,
        origin_kind: "migration", stream: STREAM, scope_key: scope_key, sequence: sequence,
        idempotency_key: "#{FORMAT}:#{mapping.id}:#{control.high_water_mark.fetch('copy_run_id')}:#{sequence}",
        mode: "unknown", complete: false, payload: payload)
      rows.each do |row|
        entry = account.entries.find(row.fetch("entry_id"))
        row.fetch("identities").each do |identity|
          observation = SourceRecord.create!(family_id: @family_id, account: account, external_account: external, ingestion_batch: batch,
            kind: row.fetch("kind"), external_id: identity.fetch("external_id"), input_external_id: identity.fetch("input_external_id"),
            input_occurrence: identity.fetch("input_occurrence"), pending: identity.fetch("pending"))
          observation.create_entry_source!(entry: entry, account: account, family_id: @family_id, role: "posting", match_method: row.fetch("match_method"),
            bootstrap_batch: batch, bootstrap_external_account: external, bootstrap_identity_role: identity.fetch("role"))
        end
      end
      batch.update!(status: "applied", applied_at: Time.current)
      state["next_sequence"] += 1
      batch
    end

    def current_mappings
      EntrySource.where(account: account, family_id: @family_id, bootstrap_external_account_id: external.id, bootstrap_identity_role: "current")
    end

    def verify_terminal_inventory!
      candidates = planner.candidate_entries
      current = current_mappings.where(active: true)
      valid = current.joins(:source_record, :entry)
        .joins("LEFT JOIN transactions bootstrap_transactions ON entries.entryable_type = 'Transaction' AND bootstrap_transactions.id = entries.entryable_id")
        .joins("LEFT JOIN trades bootstrap_trades ON entries.entryable_type = 'Trade' AND bootstrap_trades.id = entries.entryable_id")
        .where(<<~SQL.squish, source: control.provider_key, external: external.id, account: account.id, family: @family_id)
        entry_sources.entry_identity = entries.id AND entry_sources.bootstrap_entryable_type = entries.entryable_type AND
        entry_sources.bootstrap_identity_state = #{Ingestion::FinancialIdentityState.sql} AND
        (bootstrap_transactions.id IS NOT NULL OR bootstrap_trades.id IS NOT NULL) AND
        NOT EXISTS (SELECT 1 FROM entries sibling WHERE sibling.entryable_type = entries.entryable_type AND
          sibling.entryable_id = entries.entryable_id AND sibling.id <> entries.id) AND
        source_records.external_account_id = :external AND source_records.account_id = :account AND source_records.family_id = :family AND
        NOT source_records.withdrawn AND
        ((source_records.kind = 'transaction' AND entries.entryable_type = 'Transaction') OR
          (source_records.kind = 'activity' AND entries.entryable_type IN ('Transaction', 'Trade'))) AND
        ((entry_sources.match_method = 'legacy_external_id' AND entries.source = :source AND entries.external_id = source_records.external_id) OR
          (:source = 'plaid' AND entry_sources.match_method = 'legacy_plaid_id' AND entries.plaid_id = source_records.external_id AND
            (entries.source IS NULL OR entries.source IN ('', 'plaid')) AND (entries.external_id IS NULL OR entries.external_id = source_records.external_id)))
      SQL
      # Account FOR UPDATE prevents new Entry inserts through their FK during
      # this terminal check. The reverse check also catches identities changed
      # behind the sweep cursor so that they no longer appear as candidates.
      if candidates.where.not(id: valid.reselect("entry_sources.entry_id")).exists? ||
          current.where.not(id: valid.reselect("entry_sources.id")).exists? ||
          valid.where.not(entry_id: candidates.reselect("entries.id")).exists? ||
          current_mappings.count != state.fetch("captured_entries") || valid.count != state.fetch("verified_entries")
        raise Conflict, "Final financial identity inventory changed or contains uncovered entries"
      end
    end

    def save_checkpoint!(batch: nil)
      raise Conflict, "Identity bootstrap checkpoint exceeds its state bound" if Value.dump(state).bytesize > MAX_STATE_BYTES
      @checkpoint ||= checkpoint_scope.new(provider_connection: connection, family_id: @family_id, external_account: external, schema_version: 1)
      checkpoint.state = state
      checkpoint.ingestion_batch = batch if batch
      checkpoint.save!
    end

    def restart!(phase:)
      with_admission do
        load_checkpoint!(required: true)
        raise Conflict, "Capture must finish before verification can restart" if phase == "verify" && state.fetch("phase") == "capture"
        prepare_page(cursor: nil)
        state.merge!("phase" => phase, "cursor" => nil, "verified_entries" => 0)
        state.except!("verified_at", "requires_cutover_reverification")
        save_checkpoint!
        result(replayed: true)
      end
    rescue StandardError => error
      capture_failure(error)
      raise
    end

    def result(replayed:)
      Result.new(phase: state.fetch("phase").dup.freeze, checkpoint_id: checkpoint&.id, batch_id: checkpoint&.ingestion_batch_id,
        captured_entries: state.fetch("captured_entries"), verified_entries: state.fetch("verified_entries"), replayed: replayed)
    end

    def capture_failure(error)
      return if error.is_a?(Fence::Busy)
      DebugLogEntry.capture(category: "provider_migration_error", level: "error", message: "Financial identity bootstrap requires retry or review",
        source: self.class.name, provider_key: control&.provider_key, family_id: @family_id, account_provider: link,
        metadata: { migration_mapping_id: @mapping_id, error_class: error.class.name })
    rescue StandardError
      nil
    end
end
