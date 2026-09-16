# Opted-in providers retain the legacy exact settlement window, but only an
# unambiguous posting from this external account can supply financial identity.
class Ingestion::PendingTransactionMatch
  PROVIDERS = %w[akahu lunchflow redbark].freeze
  class Conflict < Ingestion::MappedEntryResolver::Conflict; end

  def initialize(external_account:, account:, batch:)
    @external_account, @account, @batch = external_account, account, batch
  end

  def resolve(record:, posted_external_id:)
    policy = (record[:metadata] || {}).with_indifferent_access[:pending_match_policy]
    return unless policy
    expected = { source: source, backward_days: 8, amount: "exact", currency: "exact" }.with_indifferent_access
    unless PROVIDERS.include?(source) && record.kind == "transaction" && !record[:pending] &&
        batch.stream == "transactions" && policy == expected && posted_external_id == record[:external_id] &&
        posted_external_id.start_with?("#{source}_") &&
        !(source.in?(%w[akahu lunchflow]) && posted_external_id.start_with?("#{source}_pending_"))
      raise Conflict, "Invalid provider pending match policy"
    end

    candidates = pending_postings(record).limit(2).to_a
    return if candidates.empty?
    raise Conflict, "Provider pending match is ambiguous" unless candidates.one?

    posting = candidates.sole
    entry = account.entries.find(posting.entry_identity)
    entry.lock!("FOR UPDATE NOWAIT")
    entry.entryable&.lock!("FOR UPDATE NOWAIT")
    observation = posting.source_record
    observation.lock!("FOR UPDATE NOWAIT")
    posting.lock!("FOR UPDATE NOWAIT")
    unless pending_postings(record).where(id: posting.id).exists?
      raise Conflict, "Provider pending match changed before publication"
    end
    original = observation.ingestion_batch
    unless original.origin_kind == "migration" || original.applied? || original.id == batch.id
      raise Conflict, "Provider pending match has no completed publication"
    end
    resolver = Ingestion::MappedEntryResolver.new(external_account: external_account, account: account,
      definition: Provider::AccountData::Registry.declared_adapter(source).definition)
    resolved = resolver.resolve_pending_transition(source_record: observation,
      pending_external_id: observation.external_id, posted_external_id: posted_external_id)
    unless resolved.entry_identity == entry.id && resolved.entry_source_id == posting.id
      raise Conflict, "Provider pending match changed financial identity"
    end
    resolved
  rescue ActiveRecord::RecordNotFound
    raise Conflict, "Provider pending match no longer exists", cause: nil
  end

  private
    attr_reader :external_account, :account, :batch

    def source
      external_account.provider_key
    end

    def pending_postings(record)
      EntrySource.joins(:source_record, :entry)
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(active: true, role: "posting", account_id: account.id, family_id: account.family_id,
          source_records: { external_account_id: external_account.id, account_id: account.id,
            family_id: account.family_id, kind: "transaction", pending: true, withdrawn: false },
          entries: { account_id: account.id, source: source, amount: record[:amount], currency: record[:currency],
            date: (record[:date] - 8)..record[:date] })
        .where("transactions.extra -> ? ->> 'pending' = 'true'", source)
    end
end
