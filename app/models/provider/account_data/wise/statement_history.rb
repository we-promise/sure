# A historical fact about an accepted statement posting, not source coverage.
# Called only inside the shared writer's fenced publication transaction.
class Provider::AccountData::Wise::StatementHistory
  FORMAT = "wise-statement-history/v1".freeze
  STREAM = "wise_statement_history".freeze
  MAX_STATE_BYTES = 64 * 1024
  MAX_BATCH_BYTES = 16 * 1024 * 1024
  Result = Data.define(:receipt, :byte_size) do
    def inspect
      "#<#{self.class.name} bytes=#{byte_size}>"
    end
  end

  def self.record_applied!(external_account:, batch:, page:)
    new(external_account).record_applied!(batch, page)
  end

  def self.capture(external_account:, observed_at:)
    new(external_account).capture(observed_at)
  end

  def initialize(external)
    @external = external
    @connection = external.provider_connection
    unless external.persisted? && connection.provider_key == "wise" && external.family_id == connection.family_id
      stale!
    end
  end

  def record_applied!(batch, page)
    raise ArgumentError, "Statement promotion requires the publication transaction" if ProviderConnection.connection.open_transactions.zero?
    return unless page.evidence["phase"] == "statements" && page.records.any?

    existing = checkpoint
    return validate!(existing) if existing

    validate_batch!(batch, page)
    binding = current_binding
    stale! unless binding == batch.source_binding
    # A secondary source can retain observations without publishing an entry.
    policy = Account::SourcePolicy.active.find_by(id: batch.source_policy_version, account_id: binding["account_id"], resource: "transactions")
    return unless policy && policy.account_provider_id == binding["account_provider_id"]

    posting = nil
    page.records.each do |record|
      next unless statement_record?(record)
      observation = SourceRecord.find_by(external_account_id: external.id, family_id: connection.family_id,
        account_id: binding["account_id"], kind: "transaction", external_id: record[:external_id],
        input_external_id: record[:external_id], input_occurrence: 0, ingestion_batch_id: batch.id, pending: false, withdrawn: false)
      mapping = observation && EntrySource.find_by(source_record_id: observation.id, family_id: connection.family_id,
        account_id: binding["account_id"], active: true, role: "posting")
      next unless mapping
      entry = Entry.select(:id, :account_id, :entryable_type).find_by(id: mapping.entry_id)
      next unless entry && entry.account_id == binding["account_id"] && entry.entryable_type == "Transaction"
      posting = { "source_record_id" => observation.id, "entry_source_id" => mapping.id,
        "entry_identity" => mapping.entry_identity, "external_id" => observation.external_id,
        "input_external_id" => observation.input_external_id, "input_occurrence" => observation.input_occurrence }
      break
    end
    return unless posting

    state = { "format" => FORMAT, "provider_connection_id" => connection.id, "family_id" => connection.family_id,
      "external_account_id" => external.id, "external_id" => external.external_id,
      "profile_id" => connection.settings.fetch("profile_id").to_s, "currency" => external.currency,
      "batch_id" => batch.id, "sync_id" => batch.sync_id, "writer_epoch" => batch.writer_epoch,
      "applied_at" => batch.applied_at.utc.iso8601(6), "source_binding" => batch.source_binding,
      "payload_fingerprint" => fingerprint(batch.payload), "posting" => posting }
    bounded_state!(state)
    connection.provider_sync_checkpoints.create!(family_id: connection.family_id, external_account: external,
      stream: STREAM, scope_key: scope_key, state: state)
  end

  def capture(observed_at)
    row = checkpoint
    return unless row
    result = validate!(row)
    # Strict inequality also excludes clock ties. A resumed factory must not
    # adopt its own newly committed promotion halfway through its page chain.
    return unless Time.iso8601(result.receipt.fetch("applied_at")) < observed_at
    result
  end

  private
    attr_reader :external, :connection

    def scope_key
      "account:#{external.id}"
    end

    def checkpoint
      scope = connection.provider_sync_checkpoints.where(stream: STREAM, scope_key: scope_key)
      bytes = scope.pick(Arel.sql("COALESCE(octet_length(state::text), 0)"))
      return unless bytes
      bounded!(bytes, MAX_STATE_BYTES)
      scope.where("COALESCE(octet_length(state::text), 0) <= ?", MAX_STATE_BYTES).first || stale!
    end

    def validate!(checkpoint)
      state = checkpoint.state
      state_bytes = bounded_state!(state)
      unless state["format"] == FORMAT && state["provider_connection_id"] == connection.id && state["family_id"] == connection.family_id &&
          state["external_account_id"] == external.id && state["external_id"] == external.external_id &&
          state["profile_id"] == connection.settings.fetch("profile_id").to_s && state["currency"] == external.currency &&
          checkpoint.family_id == connection.family_id && checkpoint.external_account_id == external.id &&
          checkpoint.schema_version == 1 &&
          checkpoint.ingestion_batch_id.nil? && checkpoint.provider_sync_generation_id.nil? && checkpoint.provider_authorization_id.nil? &&
          checkpoint.cursor.nil? && checkpoint.covered_through.nil?
        stale!
      end
      scope = connection.ingestion_batches.where(id: state.fetch("batch_id"), family_id: connection.family_id, external_account_id: external.id)
      bytes = scope.pick(Arel.sql("COALESCE(octet_length(payload::text), 0)"))
      stale! unless bytes
      bounded!(bytes, MAX_BATCH_BYTES)
      batch = scope.where("COALESCE(octet_length(payload::text), 0) <= ?", MAX_BATCH_BYTES).first || stale!
      page = Ingestion::Codec.load(batch.payload)
      validate_batch!(batch, page)
      unless state["sync_id"] == batch.sync_id && state["writer_epoch"] == batch.writer_epoch &&
          state["applied_at"] == batch.applied_at.utc.iso8601(6) && state["source_binding"] == batch.source_binding &&
          state["source_binding"] == current_binding && state["payload_fingerprint"] == fingerprint(batch.payload)
        stale!
      end
      posting = state.fetch("posting")
      unless page.records.any? { |record| statement_record?(record) && record[:external_id] == posting["external_id"] } &&
          posting["input_external_id"] == posting["external_id"] && posting["input_occurrence"] == 0
        stale!
      end
      observation = SourceRecord.select(:id, :external_id, :input_external_id, :input_occurrence).find_by(
        id: posting["source_record_id"], external_account_id: external.id, family_id: connection.family_id,
        account_id: state.dig("source_binding", "account_id"), kind: "transaction")
      mapping = EntrySource.select(:id, :entry_id, :entry_identity, :active).find_by(id: posting["entry_source_id"],
        source_record_id: posting["source_record_id"], family_id: connection.family_id,
        account_id: state.dig("source_binding", "account_id"), role: "posting")
      unless observation && mapping && observation.external_id == posting["external_id"] &&
          observation.input_external_id == posting["input_external_id"] && observation.input_occurrence == posting["input_occurrence"] &&
          mapping.entry_identity == posting["entry_identity"]
        stale!
      end
      if mapping.active?
        entry = Entry.select(:id, :account_id, :entryable_type).find_by(id: mapping.entry_id)
        stale! unless entry && entry.id == mapping.entry_identity && entry.account_id == state.dig("source_binding", "account_id") && entry.entryable_type == "Transaction"
      else
        # A legitimate entry deletion preserves this historical posting receipt.
        stale! unless mapping.entry_id.nil?
      end
      receipt = state.merge("checkpoint_id" => checkpoint.id)
      Result.new(receipt: Provider::AccountData::MigrationManifest.copy_value(receipt), byte_size: bytes + state_bytes)
    rescue KeyError, ArgumentError, TypeError, NoMethodError
      stale!
    end

    def validate_batch!(batch, page)
      unless batch.persisted? && batch.applied? && batch.applied_at && batch.origin_kind == "provider" &&
          batch.provider_connection_id == connection.id && batch.family_id == connection.family_id &&
          batch.external_account_id == external.id && batch.stream == "transactions" && batch.scope_key == scope_key &&
          batch.source_binding["publication"] == "ledger" && page.evidence["phase"] == "statements" &&
          page.evidence["wise_account"] == { "profile_id" => connection.settings.fetch("profile_id").to_s,
            "external_id" => external.external_id, "currency" => external.currency } &&
          Ingestion::Codec.dump(page) == batch.payload
        stale!
      end
      bounded!(JSON.generate(batch.payload).bytesize, MAX_BATCH_BYTES)
      stored_bytes = IngestionBatch.where(id: batch.id).pick(Arel.sql("COALESCE(octet_length(payload::text), 0)"))
      stale! unless stored_bytes
      bounded!(stored_bytes, MAX_BATCH_BYTES)
    end

    def statement_record?(record)
      wise = (record[:metadata] || {}).with_indifferent_access.dig(:extra, :wise)
      record.kind == "transaction" && record[:pending] == false && wise.is_a?(Hash) && wise[:statement_id].present? &&
        record[:external_id] == "wise_statement_#{wise[:statement_id]}"
    end

    def current_binding
      Provider::AccountData::GenerationAccounts.new(connection, resource: "transactions",
        identity_namespace: external.identity_namespace).capture_one(external)
    end

    def fingerprint(payload)
      Provider::AccountData::RuntimeInputs.fingerprint(payload, purpose: FORMAT)
    end

    def bounded_state!(state)
      stale! unless state.is_a?(Hash)
      JSON.generate(state).bytesize.tap { |bytes| bounded!(bytes, MAX_STATE_BYTES) }
    end

    def bounded!(bytes, limit)
      raise Provider::AccountData::IncompletePage, "Wise statement evidence exceeds its read bound" if bytes > limit
    end

    def stale!
      raise Provider::AccountData::StaleWriter, "Wise statement-history evidence or binding changed"
    end
end
