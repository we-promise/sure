require "set"

# Shared authentication for cached transactions at cutover. The caller owns the
# exclusive legacy permit, final transaction and original account/copy checks.
# Keep one instance for the complete verification so proof bytes stay bounded
# across accounts. Providers decide whether each authenticated cached version is
# already disposed; this helper never imports it or grants history coverage.
class Provider::AccountData::MigrationHistoryProof
  class Conflict < Provider::AccountData::StaleWriter; end

  def initialize(connection:, control:, family_id:, source:, max_bytes:, max_identity_bytes:)
    @connection, @control, @family_id, @source = connection, control, family_id, source
    @max_bytes, @max_identity_bytes = max_bytes, max_identity_bytes
    @proof_bytes = 0
    @proof_ids = Set.new
    @proof_batch = nil
  end

  def verify_transaction!(record:, mapping:, external:, link:, account:)
    raise ArgumentError, "History proof verification requires the final cutover transaction" if ApplicationRecord.connection.open_transactions.zero?

    observation = SourceRecord.where(external_account_id: external.id, kind: "transaction", external_id: record[:external_id]).sole
    postings = observation.entry_sources.limit(2).to_a
    posting = postings.first
    unless observation.account_id == account.id && observation.family_id == @family_id && !observation.withdrawn? &&
        postings.one? && posting.active? && posting.role == "posting" && posting.entry_id &&
        posting.bootstrap_batch_id == observation.ingestion_batch_id
      # Retained deletion evidence is not a supported native suppression rule.
      raise Conflict, "Cached identity needs an explicit financial disposition"
    end
    entry = account.entries.select(:id, :account_id, :entryable_type, :entryable_id, :source, :external_id, :plaid_id)
      .lock("FOR UPDATE NOWAIT").find(posting.entry_id)
    unless entry.entryable_type == "Transaction" && entry.source == @source && entry.plaid_id.blank? &&
        Entry.where(entryable_type: "Transaction", entryable_id: entry.entryable_id).count == 1
      raise Conflict, "Cached financial identity changed"
    end
    Transaction.where(id: entry.entryable_id).select(:id).lock("FOR UPDATE NOWAIT").first!
    posting.association(:entry).target = entry
    batch = proof_batch!(posting.bootstrap_batch_id)
    posting.association(:bootstrap_batch).target = batch
    found = Ingestion::LegacyIdentityEvidence.for_mapping!(entry_source: posting, source_record: observation)
    row, identity = found.values_at(:row, :identity)
    plan = batch.payload.fetch("plan")
    expected = { "family_id" => @family_id, "account_id" => account.id, "provider_connection_id" => @connection.id,
      "external_account_id" => external.id, "identity_namespace" => external.identity_namespace,
      "account_provider_id" => link.id, "account_provider_revision" => link.lock_version,
      "account_currency" => account.currency, "accountable_type" => account.accountable_type, "accountable_id" => account.accountable_id,
      "external_account_external_id" => external.external_id, "legacy_account_id" => mapping.legacy_id,
      "migration_mapping_id" => mapping.id, "archive_checksum" => mapping.source_checksum,
      "copy_run_id" => @control.high_water_mark.fetch("copy_run_id"), "source" => @source }
    unless expected.all? { |key, value| plan[key] == value } && row["entry_id"] == entry.id &&
        row["entryable_type"] == "Transaction" && row["external_id"] == entry.external_id &&
        row["identity_state"] == current_identity_state!(entry) &&
        observation.pending? == identity["pending"] && yield(row, identity)
      raise Conflict, "Cached identity differs from its original financial proof"
    end
    true
  rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded, KeyError, TypeError,
      Provider::AccountData::InvalidResponse, Ingestion::LegacyIdentityEvidence::InvalidEvidence
    raise Conflict, "Cached history requires exact retained financial provenance", cause: nil
  end

  private
    def proof_batch!(id)
      return @proof_batch if @proof_batch&.id == id
      scope = IngestionBatch.where(id: id, family_id: @family_id, provider_connection_id: @connection.id)
      bytes = scope.pick(Arel.sql("octet_length(payload)"))
      raise Conflict, "History has missing or oversized financial proof" unless bytes && bytes <= @max_bytes
      if @proof_ids.add?(id)
        @proof_bytes += bytes
        raise Conflict, "History exceeds its financial proof bound" if @proof_bytes > @max_bytes
      end
      @proof_batch = scope.where("octet_length(payload) <= ?", @max_bytes).first!
    end

    def current_identity_state!(entry)
      sql = Ingestion::FinancialIdentityState.sql
      scope = Entry.where(id: entry.id).joins("INNER JOIN transactions bootstrap_transactions ON bootstrap_transactions.id = entries.entryable_id")
      state = scope.where("octet_length((#{sql})::text) <= ?", @max_identity_bytes).pick(Arel.sql(sql))
      raise Conflict, "Financial identity is missing or exceeds its bound" unless state
      state
    end
end
