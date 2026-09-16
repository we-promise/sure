# Read-only identity resolution. This is intentionally separate from the writer:
# returning a reviewed UUID does not authorize publication or bypass protection.
class Ingestion::MappedEntryResolver
  class Conflict < Provider::AccountData::InvalidResponse; end

  Result = Data.define(:status, :entry, :entry_identity, :source_record_id, :entry_source_id, :current_external_id,
    :definition, :external_account_id, :account_id, :kind, :external_id, :previous_external_id) do
    def resolved?
      status == "resolved"
    end

    def retired_alias?
      status == "retired_alias"
    end

    def unmapped?
      status == "unmapped"
    end

    def pending_transition?
      status == "pending_transition"
    end

    def inspect
      "#<#{self.class.name} status=#{status}>"
    end
  end

  # Re-resolve the durable mapping inside the import transaction. A plain Entry
  # or caller-supplied UUID cannot bypass the normal importer identity checks.
  def self.for_import!(result, account:, external_id:, source:, entryable_type:)
    unless result.is_a?(Result) && (result.resolved? || result.pending_transition?) &&
        result.account_id == account.id && result.external_id == external_id &&
        result.definition.is_a?(Provider::AccountData::Definition) && result.definition.source == source
      raise Conflict, "Import requires a resolved provider identity"
    end
    external = ExternalAccount.find_by!(id: result.external_account_id, family_id: account.family_id)
    locked_entry = account.entries.lock.find(result.entry_identity)
    locked_entry.entryable&.lock!
    observation = SourceRecord.find_by!(id: result.source_record_id, family_id: account.family_id, external_account_id: external.id)
    resolver = new(external_account: external, account: account, definition: result.definition)
    fresh = if result.pending_transition?
      raise Conflict, "Only cash transactions can claim pending identities" unless entryable_type == "Transaction"
      resolver.resolve_pending_transition(source_record: observation, pending_external_id: result.previous_external_id, posted_external_id: external_id)
    else
      resolver.resolve(source_record: observation, kind: result.kind, external_id: external_id, entryable_type: entryable_type)
    end
    unless fresh.entry_identity == result.entry_identity && fresh.entry_source_id == result.entry_source_id && fresh.status == result.status
      raise Conflict, "Resolved provider identity changed before import"
    end
    fresh.entry
  rescue ActiveRecord::RecordNotFound
    raise Conflict, "Resolved provider identity no longer exists", cause: nil
  end

  def initialize(external_account:, account:, definition:)
    @external_account, @account, @definition = external_account, account, definition
  end

  # definition comes from a declared adapter, never request metadata. The caller
  # must resolve before changing the observation and hold the publication fences
  # through the later importer call; this helper acquires no writer permission.
  def resolve(source_record:, kind:, external_id:, entryable_type:)
    validate_context!(kind, entryable_type)
    unless external_id.is_a?(String) && external_id.present? && source_record&.persisted?
      raise Conflict, "Mapped identity requires a persisted source observation"
    end
    observation = SourceRecord.find_by!(id: source_record.id, family_id: account.family_id, external_account_id: external_account.id)
    validate_observation!(observation, kind, external_id)
    mappings = observation.entry_sources.to_a
    if mappings.empty?
      raise Conflict, "Migration observations require a reviewed posting mapping" if observation.ingestion_batch.origin_kind == "migration"
      return outcome("unmapped", observation)
    end
    unless mappings.size == 1 && mappings.first.active? && mappings.first.role == "posting"
      raise Conflict, "Historical or corroborating evidence cannot select a financial posting"
    end
    mapping = mappings.first
    entry = account.entries.find_by(id: mapping.entry_id)
    unless entry && mapping.entry_identity == entry.id && mapping.account_id == account.id &&
        mapping.family_id == account.family_id && entry.account_id == account.id &&
        observation.account_id == account.id && entry.entryable_type == entryable_type &&
        entry.entryable&.class&.name == entryable_type
      raise Conflict, "Mapped financial UUID has a different account, family or type"
    end
    bootstrap = bootstrap_identity(mapping, observation)
    if account.entries.where(source: source, external_id: external_id).where.not(id: entry.id).exists?
      raise Conflict, "Provider identity already selects another financial UUID"
    end
    if source == "plaid" && account.entries.where(plaid_id: external_id).where.not(id: entry.id).exists?
      raise Conflict, "Legacy Plaid identity already selects another financial UUID"
    end
    if bootstrap && bootstrap.fetch(:identity).fetch("role") == "retired_alias"
      current_id = bootstrap_alias_current_identity(entry, external_id, mapping, bootstrap)
      return outcome("retired_alias", observation, mapping, current_external_id: current_id)
    end
    if kind == "transaction" && retired_pending_alias?(entry, external_id)
      # No writable Entry is returned for a retired alias. A caller must skip
      # financial publication rather than falling through to manual matching.
      return outcome("retired_alias", observation, mapping, current_external_id: entry.external_id)
    end
    raise Conflict, "Withdrawn evidence needs an explicit reconciliation decision" if observation.withdrawn?
    unless current_identity?(entry, external_id, mapping)
      raise Conflict, "Mapped financial UUID has a different provider identity"
    end
    outcome("resolved", observation, mapping, entry: entry, current_external_id: external_id)
  rescue ActiveRecord::RecordNotFound
    raise Conflict, "Mapped identity context no longer exists", cause: nil
  rescue Ingestion::LegacyIdentityEvidence::InvalidEvidence
    raise Conflict, "Mapped identity bootstrap evidence is invalid", cause: nil
  end

  def resolve_pending_transition(source_record:, pending_external_id:, posted_external_id:)
    unless posted_external_id.is_a?(String) && posted_external_id.present? && posted_external_id != pending_external_id
      raise Conflict, "Pending transition requires a distinct explicit posted identity"
    end
    result = resolve(source_record: source_record, kind: "transaction", external_id: pending_external_id, entryable_type: "Transaction")
    pending_extra = result.entry&.transaction&.extra
    pending_data = pending_extra[source] if pending_extra.is_a?(Hash)
    unless result.resolved? && pending_data.is_a?(Hash) && ActiveModel::Type::Boolean.new.cast(pending_data["pending"])
      raise Conflict, "Explicit pending identity is not a current pending posting"
    end
    raise Conflict, "Pending observation is no longer current" unless source_record.reload.pending? && !source_record.withdrawn?
    if account.entries.where(source: source, external_id: posted_external_id).where.not(id: result.entry_identity).exists? ||
        (source == "plaid" && account.entries.where(plaid_id: posted_external_id).where.not(id: result.entry_identity).exists?)
      raise Conflict, "Posted identity already belongs to another financial UUID"
    end
    posted = SourceRecord.find_by(external_account: external_account, kind: "transaction", external_id: posted_external_id)
    if posted && (posted.withdrawn? || posted.entry_sources.exists? || (posted.account_id && posted.account_id != account.id))
      raise Conflict, "Posted identity already has financial history"
    end
    Result.new(**result.to_h.merge(status: "pending_transition".freeze, external_id: posted_external_id,
      current_external_id: posted_external_id, previous_external_id: pending_external_id))
  end

  private
    attr_reader :external_account, :account, :definition

    def source
      definition.source
    end

    def validate_context!(kind, entryable_type)
      unless definition.is_a?(Provider::AccountData::Definition) && external_account&.persisted? && account&.persisted? &&
          definition.key == external_account.provider_key &&
          { "transaction" => [ "Transaction" ], "activity" => %w[Transaction Trade] }.fetch(kind, []).include?(entryable_type)
        raise Conflict, "Mapped identity needs a declared provider and supported financial type"
      end
      external_account.reload
      account.reload
      link = external_account.account_provider
      unless definition.key == external_account.provider_key && external_account.family_id == account.family_id &&
          external_account.provider_connection.family_id == account.family_id && link && link.account_id == account.id &&
          link.family_id == account.family_id && link.provider_key == definition.key
        raise Conflict, "Mapped identity belongs to another provider account or family"
      end
    end

    def validate_observation!(observation, kind, external_id)
      batch = observation.ingestion_batch
      unless observation.external_account_id == external_account.id && observation.account_statement_id.nil? &&
          observation.family_id == account.family_id && (observation.account_id.nil? || observation.account_id == account.id) &&
          observation.kind == kind && observation.external_id == external_id &&
          batch.family_id == account.family_id && batch.provider_connection_id == external_account.provider_connection_id &&
          batch.external_account_id == external_account.id
        raise Conflict, "Observation does not identify the requested provider account and resource"
      end
      if batch.origin_kind == "migration"
        Ingestion::LegacyIdentityEvidence.for_observation!(source_record: observation)
        return
      end
      unless batch.origin_kind == "provider" && batch.stream == { "transaction" => "transactions", "activity" => "activities" }.fetch(kind) &&
          batch.sync&.syncable_type == "ProviderConnection" && batch.sync.syncable_id == external_account.provider_connection_id
        raise Conflict, "Mapped identity evidence has no supported publication origin"
      end
    end

    def bootstrap_identity(mapping, observation)
      unless mapping.bootstrap_batch_id || mapping.bootstrap_external_account_id || mapping.bootstrap_identity_role
        raise Conflict, "Migration posting has no permanent bootstrap proof" if observation.ingestion_batch.origin_kind == "migration"
        return
      end

      # The observation's latest batch advances on native refresh. The original
      # UUID assertion remains attached to the mapping and must still be valid.
      Ingestion::LegacyIdentityEvidence.for_mapping!(entry_source: mapping, source_record: observation)
    end

    def bootstrap_alias_current_identity(entry, external_id, mapping, bootstrap)
      unless entry.transaction? && bootstrap.fetch(:row).fetch("entryable_type") == "Transaction"
        raise Conflict, "Only a transaction can retain a pending identity alias"
      end
      current_id = if entry.source == source && entry.external_id.present?
        entry.external_id
      elsif current_identity?(entry, bootstrap.fetch(:row).fetch("external_id"), mapping)
        bootstrap.fetch(:row).fetch("external_id")
      end
      unless current_id && current_id != external_id
        raise Conflict, "Retired identity no longer has a distinct current provider posting"
      end
      current_id
    end

    def current_identity?(entry, external_id, mapping)
      return true if entry.source == source && entry.external_id == external_id

      # The older Plaid column is admitted only by an explicit reviewed mapping.
      # Other providers and unscoped/manual identities get no generic fallback.
      source == "plaid" && mapping.match_method == "legacy_plaid_id" && entry.plaid_id == external_id &&
        [ nil, "", "plaid" ].include?(entry.source) && [ nil, external_id ].include?(entry.external_id)
    end

    def retired_pending_alias?(entry, external_id)
      return false unless entry.transaction? && entry.source == source && entry.external_id.present? && entry.external_id != external_id
      extra = entry.transaction.extra
      return false unless extra.is_a?(Hash)
      provider_data = extra[source]
      aliases = extra["auto_claimed_pending_ids"]
      if !aliases.nil? && (!aliases.is_a?(Array) || aliases.any? { |id| !id.is_a?(String) || id.blank? })
        raise Conflict, "Pending identity evidence is malformed"
      end
      Array(aliases).include?(external_id) || (source == "plaid" && provider_data.is_a?(Hash) &&
        provider_data["pending"] == false && provider_data["pending_transaction_id"] == external_id)
    end

    def outcome(status, observation, mapping = nil, entry: nil, current_external_id: nil)
      Result.new(status: status.freeze, entry: entry, entry_identity: mapping&.entry_identity,
        source_record_id: observation.id, entry_source_id: mapping&.id, current_external_id: current_external_id,
        definition: definition, external_account_id: external_account.id, account_id: account.id, kind: observation.kind,
        external_id: observation.external_id, previous_external_id: nil)
    end
end
