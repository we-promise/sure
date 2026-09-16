require "set"

# Resolve deprecated /buys and /sells identities from retained provider facts.
# Called only inside the shared writer's admitted account publication transaction.
# No economic/date/name matching and no mutation of the retained financial UUID.
class Provider::AccountData::Coinbase::LegacyTradeIdentity
  class Conflict < Provider::AccountData::InvalidResponse; end

  MAX_ROWS = 10_000
  MAX_BYTES = 32 * 1024 * 1024
  MAX_ID_BYTES = 512

  def initialize(external_account:, account:, batch:)
    @external, @account, @batch = external_account, account, batch
  end

  def resolve(record)
    require_context!
    unless record.kind == "activity" && record.ledger_type == "trade" && %w[buy sell].include?(record[:activity_type]) &&
        record[:external_id].start_with?("coinbase_txn_")
      return record[:external_id]
    end
    load_archive! unless @loaded
    native_id, type = record[:external_id], record[:activity_type]
    explicit = record[:metadata]&.with_indifferent_access&.fetch(:legacy_buy_sell_id, nil)
    explicit = identifier!(explicit) unless explicit.nil?
    archived = @transactions[native_id]
    if archived && (archived.fetch(:type) != type || (explicit && archived[:legacy_id] && explicit != archived[:legacy_id]))
      raise Conflict, "Coinbase transaction conflicts with its retained endpoint identity"
    end
    raw_legacy_id = explicit || archived&.fetch(:legacy_id)
    unless raw_legacy_id
      if @known.any? { |id| id.start_with?("coinbase_#{type}_") }
        raise Conflict, "Coinbase retained trade needs an explicit endpoint identity"
      end
      return native_id
    end
    legacy_id = "coinbase_#{type}_#{raw_legacy_id}"
    legacy = @legacy[legacy_id]
    retained_relation = archived && archived[:legacy_id] == raw_legacy_id && archived[:status] == "completed"
    unless legacy || retained_relation || @known.include?(legacy_id)
      return native_id
    end
    unless @retained && (retained_relation || legacy == "completed")
      raise Conflict, "Coinbase legacy identity has no exact retained provider relation"
    end
    if @reverse[legacy_id] && @reverse[legacy_id] != native_id
      raise Conflict, "Coinbase endpoint identity already belongs to another transaction"
    end
    if account.entries.where(external_id: native_id).exists? || SourceRecord.where(external_account: external, external_id: native_id).exists?
      raise Conflict, "Coinbase transaction already has a competing financial identity"
    end
    verify_captured_relation!(batch, legacy_id: legacy_id, native_id: native_id, current_record: record)
    verify_original_posting!(legacy_id, native_id: native_id)
    legacy_id
  rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded, KeyError, ArgumentError, TypeError,
      Ingestion::LegacyIdentityEvidence::InvalidEvidence, Provider::AccountData::MigrationCopier::Conflict
    raise Conflict, "Coinbase legacy trade identity requires exact retained proof", cause: nil
  end

  private
    attr_reader :external, :account, :batch

    def require_context!
      link = external.account_provider
      policy = Account::SourcePolicy.active.find_by(account_id: account.id, resource: "activities")
      unless ApplicationRecord.connection.open_transactions.positive? && external.provider_key == "coinbase" &&
          external.family_id == account.family_id && external.provider_connection.family_id == account.family_id &&
          link && link.account_id == account.id && link.family_id == account.family_id && link.provider_key == "coinbase" &&
          policy && policy.account_provider_id == link.id && batch.source_policy_version == policy.id &&
          batch.origin_kind == "provider" && batch.stream == "activities" && batch.external_account_id == external.id &&
          batch.family_id == account.family_id && batch.provider_connection_id == external.provider_connection_id &&
          batch.source_binding["account_id"] == account.id && batch.source_binding["account_provider_id"] == link.id
        raise Conflict, "Coinbase alias requires the selected captured financial source"
      end
    end

    def load_archive!
      # Include retained deleted/unsigned identities: absence of an active Entry
      # is never permission to recreate an old trade under its new endpoint ID.
      prefix_sql = "external_id LIKE 'coinbase_buy_%' OR external_id LIKE 'coinbase_sell_%'"
      entries = account.entries.where(source: "coinbase").where(prefix_sql).limit(MAX_ROWS + 1).pluck(:external_id)
      observations = SourceRecord.where(external_account: external).where(prefix_sql).limit(MAX_ROWS + 1).pluck(:external_id)
      raise Conflict, "Coinbase financial identity inventory exceeds its bound" if entries.size + observations.size > MAX_ROWS
      @known = (entries + observations).to_set
      @transactions, @legacy, @reverse, @proof_batches = {}, {}, {}, {}
      @proof_bytes = 0
      @retained = Provider::AccountData::RetainedRow.new(connection: external.provider_connection, provider_key: "coinbase").account(external)
      if @retained
        raise Conflict, "Coinbase retained history exceeds its byte bound" if @retained.byte_size > MAX_BYTES
        Provider::AccountData::MigrationCopier.verify_account_binding!(archive: @retained.archive,
          link: external.account_provider, financial: account)
        values = @retained.attributes
        unless values["account_id"] == external.external_id && values["id"] == @retained.context["legacy_id"] &&
            @retained.context["family_id"] == account.family_id && @retained.context["provider_connection_id"] == external.provider_connection_id
          raise Conflict, "Coinbase retained history belongs to another wallet"
        end
        parse_payload!(values["raw_transactions_payload"])
      end
      @loaded = true
    end

    def parse_payload!(payload)
      return if payload.nil?
      raise ArgumentError unless payload.is_a?(Hash)
      arrays = %w[transactions buys sells].to_h { |key| [ key, payload.fetch(key, []) ] }
      unless arrays.values.all? { |rows| rows.is_a?(Array) } && arrays.values.sum(&:size) <= MAX_ROWS
        raise Conflict, "Coinbase retained endpoint history exceeds its row bound"
      end
      %w[buy sell].each do |type|
        arrays.fetch("#{type}s").each do |row|
          raise ArgumentError unless row.is_a?(Hash)
          id, status = identifier!(row["id"]), identifier!(row["status"])
          key = "coinbase_#{type}_#{id}"
          raise Conflict, "Coinbase retained endpoint identity is repeated" if @legacy.key?(key)
          @legacy[key] = status
        end
      end
      arrays.fetch("transactions").each do |row|
        raise ArgumentError unless row.is_a?(Hash)
        id, type, status = identifier!(row["id"]), identifier!(row["type"]), identifier!(row["status"])
        next unless %w[buy sell].include?(type)
        key = "coinbase_txn_#{id}"
        raise Conflict, "Coinbase retained transaction identity is repeated" if @transactions.key?(key)
        details = row[type]
        raise ArgumentError unless details.nil? || details.is_a?(Hash)
        legacy_id = details && details["id"]
        legacy_id = identifier!(legacy_id) unless legacy_id.nil?
        @transactions[key] = { type: type, legacy_id: legacy_id, status: status }
        next unless legacy_id
        legacy_key = "coinbase_#{type}_#{legacy_id}"
        if @reverse.key?(legacy_key)
          raise Conflict, "Coinbase retained endpoint equivalence is ambiguous or incomplete"
        end
        @reverse[legacy_key] = key
      end
    end

    def verify_original_posting!(legacy_id, native_id:)
      observation = SourceRecord.where(external_account: external, kind: "activity", external_id: legacy_id).lock("FOR UPDATE NOWAIT").sole
      postings = observation.entry_sources.order(:id).limit(2).lock("FOR UPDATE NOWAIT").to_a
      posting = postings.first
      unless observation.family_id == account.family_id && observation.account_id == account.id && !observation.withdrawn? &&
          postings.one? && posting.active? && posting.role == "posting" && posting.bootstrap_identity_role == "current" &&
          posting.bootstrap_entryable_type == "Trade" && posting.entry_id
        raise Conflict, "Coinbase old trade has no live original financial posting"
      end
      if observation.ingestion_batch_id != posting.bootstrap_batch_id
        previous = proof_batch!(observation.ingestion_batch_id)
        unless previous.applied? || previous.id == batch.id
          raise Conflict, "Coinbase alias observation has no committed previous input"
        end
        verify_captured_relation!(previous, legacy_id: legacy_id, native_id: native_id)
      end
      entry = account.entries.select(:id, :account_id, :entryable_type, :entryable_id, :source, :external_id, :plaid_id)
        .lock("FOR UPDATE NOWAIT").find(posting.entry_id)
      unless entry.source == "coinbase" && entry.external_id == legacy_id && entry.plaid_id.blank? && entry.entryable_type == "Trade" &&
          Entry.where(entryable_type: "Trade", entryable_id: entry.entryable_id).count == 1 &&
          !account.entries.where(external_id: legacy_id).where.not(id: entry.id).exists?
        raise Conflict, "Coinbase old trade changed its financial identity"
      end
      Trade.where(id: entry.entryable_id).select(:id).lock("FOR UPDATE NOWAIT").first!
      posting.association(:entry).target = entry
      proof = proof_batch!(posting.bootstrap_batch_id)
      posting.association(:bootstrap_batch).target = proof
      found = Ingestion::LegacyIdentityEvidence.for_mapping!(entry_source: posting, source_record: observation)
      original = found.fetch(:row)
      expected = { "family_id" => account.family_id, "account_id" => account.id, "provider_connection_id" => external.provider_connection_id,
        "external_account_id" => external.id, "identity_namespace" => external.identity_namespace,
        "account_provider_id" => external.account_provider.id, "account_provider_revision" => external.account_provider.lock_version,
        "account_currency" => account.currency, "accountable_type" => account.accountable_type, "accountable_id" => account.accountable_id,
        "migration_mapping_id" => @retained.context.fetch("mapping_id"), "archive_checksum" => @retained.context.fetch("source_checksum"),
        "copy_run_id" => @retained.context.fetch("copy_run_id"), "source" => "coinbase" }
      plan = proof.payload.fetch("plan")
      state = Ingestion::FinancialIdentityState.from_snapshot("entry" => entry.attributes, "entryable" => {})
      unless expected.all? { |key, value| plan[key] == value } && original["identity_state"] == state &&
          original["external_id"] == legacy_id && found.fetch(:identity)["role"] == "current"
        raise Conflict, "Coinbase old trade differs from its original retained identity"
      end
    end

    def verify_captured_relation!(capture, legacy_id:, native_id:, current_record: nil)
      persisted = proof_batch!(capture.id)
      binding = persisted.source_binding
      unless persisted.origin_kind == "provider" && persisted.stream == "activities" && persisted.sync&.syncable_type == "ProviderConnection" &&
          persisted.sync.syncable_id == external.provider_connection_id && binding["account_id"] == account.id &&
          binding["account_provider_id"] == external.account_provider.id && binding["publication"] == "ledger"
        raise Conflict, "Coinbase alias has no captured provider publication input"
      end
      records = Ingestion::Codec.load(persisted.payload).records
      raise Conflict, "Coinbase alias input exceeds its row bound" if records.size > MAX_ROWS
      matches = records.select do |candidate|
        next false unless candidate.kind == "activity" && candidate.ledger_type == "trade" && %w[buy sell].include?(candidate[:activity_type])
        type = candidate[:activity_type]
        explicit = candidate[:metadata]&.with_indifferent_access&.fetch(:legacy_buy_sell_id, nil)
        original = @transactions[candidate[:external_id]]
        id = explicit || (original && original[:type] == type && original[:legacy_id])
        id && "coinbase_#{type}_#{id}" == legacy_id
      end
      unless matches.one? && matches.first[:external_id] == native_id &&
          (current_record.nil? || matches.first.attributes == current_record.attributes)
        raise Conflict, "Coinbase endpoint identity has conflicting captured transaction inputs"
      end
    end

    def proof_batch!(id)
      return @proof_batches.fetch(id) if @proof_batches.key?(id)
      scope = IngestionBatch.where(id: id, family_id: account.family_id, provider_connection_id: external.provider_connection_id,
        external_account_id: external.id)
      bytes = scope.pick(Arel.sql("octet_length(payload)"))
      raise Conflict, "Coinbase retained financial proof is missing or oversized" unless bytes && bytes <= MAX_BYTES
      @proof_bytes += bytes
      raise Conflict, "Coinbase retained financial proofs exceed their byte bound" if @proof_bytes > MAX_BYTES
      @proof_batches[id] = scope.where("octet_length(payload) <= ?", MAX_BYTES).first!
    end

    def identifier!(value)
      raise ArgumentError unless value.is_a?(String) && value.present? && value.bytesize <= MAX_ID_BYTES
      value
    end
end
