# Akahu's persisted suffix is a collision allocation, never an API occurrence.
# Only the unsuffixed, collision-free original can use the existing signed zero
# occurrence. Keep withdrawn aliases discoverable before generic allocation.
class Provider::AccountData::Akahu::PendingIdentity
  class Conflict < Ingestion::MappedEntryResolver::Conflict; end
  BASE = /\Aakahu_pending_[0-9a-f]{32}\z/

  def initialize(external_account:, account:)
    @external_account, @account = external_account, account
  end

  # Called with the identity already authenticated by MigrationHistoryProof.
  def verify_bootstrap!(record:, row:, identity:)
    validate_record!(record)
    unless record[:pending] && occurrence(record).zero? &&
        identity.values_at("external_id", "input_external_id", "input_occurrence") == [ record[:external_id], record[:external_id], 0 ]
      raise Conflict, "Akahu pending cache has no exact original occurrence"
    end
    # The legacy hash did not include currency. Its signed original unit must
    # remain part of identity even after current account inventory changes unit.
    original = Provider::AccountData::MigrationValue.decode(row.fetch("financial_snapshot"))
    unless original.fetch("entry").fetch("currency") == record[:currency]
      raise Conflict, "Akahu pending input changed its original monetary unit"
    end
    assert_no_suffix!(record[:external_id])
    true
  end

  def resolve(record:)
    validate_record!(record)
    base = record[:external_id]
    original = observations.find_by(external_id: base)
    migrated = original && original.entry_sources.where.not(bootstrap_batch_id: nil).exists?
    if migrated
      raise Conflict, "Repeated Akahu pending input needs occurrence reconciliation" unless occurrence(record).zero?
      assert_no_suffix!(base)
    end
    candidates = observations.where(input_external_id: base, input_occurrence: occurrence(record)).limit(2).to_a
    raise Conflict, "Akahu pending input has ambiguous financial provenance" if candidates.size > 1
    observation = candidates.first
    if migrated && observation&.id != original.id
      raise Conflict, "Akahu pending input lost its signed original occurrence"
    end
    return unless observation && (migrated || observation.withdrawn? || observation.entry_sources.exists?)

    resolved = Ingestion::MappedEntryResolver.new(external_account: external_account, account: account,
      definition: Provider::AccountData::Registry.declared_adapter("akahu").definition)
      .resolve(source_record: observation, kind: "transaction", external_id: observation.external_id, entryable_type: "Transaction")
    if migrated
      mapping = observation.entry_sources.sole
      proof = Ingestion::LegacyIdentityEvidence.for_mapping!(entry_source: mapping, source_record: observation)
      verify_bootstrap!(record: record, row: proof.fetch(:row), identity: proof.fetch(:identity))
    elsif resolved.resolved? && resolved.entry.currency != record[:currency]
      # Native-only current postings have no bootstrap snapshot. Their mapped
      # financial unit still prevents a unit-less hash from silently rebinding.
      raise Conflict, "Akahu pending input changed its mapped monetary unit"
    end
    unless resolved.resolved? || resolved.retired_alias?
      raise Conflict, "Akahu pending input requires a reviewed posting"
    end
    if observation.withdrawn? && !resolved.retired_alias?
      raise Conflict, "Withdrawn Akahu pending input requires explicit disposition"
    end
    observation.external_id
  rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded, Ingestion::LegacyIdentityEvidence::InvalidEvidence, KeyError, TypeError
    raise Conflict, "Akahu pending financial provenance changed", cause: nil
  end

  private
    attr_reader :external_account, :account

    def validate_record!(record)
      raise ArgumentError, "Akahu pending identity requires its publication transaction" unless ApplicationRecord.connection.transaction_open?
      unless external_account.provider_key == "akahu" && external_account.family_id == account.family_id &&
          record.kind == "transaction" && record[:external_id].is_a?(String) && BASE.match?(record[:external_id]) &&
          record[:metadata].with_indifferent_access[:identity_policy] == "reuse_pending_or_allocate_suffix" &&
          occurrence(record).is_a?(Integer) && occurrence(record) >= 0
        raise Conflict, "Invalid Akahu pending identity contract"
      end
    end

    def occurrence(record)
      record[:metadata].with_indifferent_access.fetch(:identity_occurrence, 0)
    end

    def observations
      SourceRecord.where(external_account_id: external_account.id, kind: "transaction")
    end

    def assert_no_suffix!(base)
      pattern = "#{Entry.sanitize_sql_like("#{base}_")}%"
      if observations.where("external_id LIKE ?", pattern).exists? ||
          account.entries.where(source: "akahu").where("external_id LIKE ?", pattern).exists?
        raise Conflict, "Akahu persisted suffixes require explicit occurrence reconciliation"
      end
    end
end
