# Lunch Flow can return an ID-less pending observation after its posted entry.
# Retain that observation as corroborating evidence; it never owns the posting.
class Provider::AccountData::Lunchflow::PostedMatch
  MATCH_METHOD = "lunchflow_posted_match".freeze
  class Conflict < Ingestion::MappedEntryResolver::Conflict; end

  def initialize(external_account:, account:, batch:)
    @external_account, @account, @batch = external_account, account, batch
  end

  def apply(record:, observation:)
    metadata = (record[:metadata] || {}).with_indifferent_access
    return false unless metadata[:posted_match_policy]
    validate_policy!(record, metadata)
    mappings = observation.persisted? ? observation.entry_sources.limit(2).to_a : []
    return false if mappings.one? && mappings.first.role == "posting"
    unless mappings.empty? || (mappings.one? && mappings.first.active? &&
        mappings.first.role == "evidence" && mappings.first.match_method == MATCH_METHOD)
      raise Conflict, "Lunch Flow pending observation has conflicting evidence"
    end
    if observation.persisted? && (observation.withdrawn? ||
        (observation.account_id && observation.account_id != account.id))
      raise Conflict, "Lunch Flow pending observation is no longer current"
    end

    retained = mappings.first
    candidates = posting_scope
    if retained
      candidates = candidates.where(entry_id: retained.entry_identity)
    else
      candidates = candidates.where(entries: { amount: record[:amount], currency: record[:currency],
        date: record[:date]..(record[:date] + 8) })
      candidates = candidates.where(entries: { name: record[:name] }) if metadata[:posted_match_policy][:name] == "exact"
    end
    candidates = candidates.limit(2).to_a
    return false if candidates.empty? && !retained
    raise Conflict, "Lunch Flow posted match is missing or ambiguous" unless candidates.one?

    posting = candidates.sole
    entry = account.entries.find(posting.entry_identity)
    entry.lock!("FOR UPDATE NOWAIT")
    entry.entryable&.lock!("FOR UPDATE NOWAIT")
    posting.source_record.lock!("FOR UPDATE NOWAIT")
    posting.lock!("FOR UPDATE NOWAIT")
    if observation.persisted?
      observation.lock!("FOR UPDATE NOWAIT")
      retained&.lock!("FOR UPDATE NOWAIT")
      unless !observation.withdrawn? && (observation.account_id.nil? || observation.account_id == account.id) &&
          observation.entry_sources.pluck(:id) == mappings.map(&:id) && (!retained || retained.active?)
        raise Conflict, "Lunch Flow pending evidence changed before publication"
      end
    end
    unless posting_scope.where(id: posting.id).exists? && (retained ||
        (entry.amount == record[:amount] && entry.currency == record[:currency] &&
          (record[:date]..(record[:date] + 8)).cover?(entry.date) &&
          (metadata[:posted_match_policy][:name].nil? || entry.name == record[:name])))
      raise Conflict, "Lunch Flow posted match changed before publication"
    end
    verify_posting!(posting, entry)
    if retained
      unless retained.entry_id == entry.id && retained.entry_identity == entry.id &&
          retained.account_id == account.id && retained.family_id == account.family_id
        raise Conflict, "Lunch Flow retained match changed financial identity"
      end
    elsif EntrySource.where(entry_id: entry.id, role: "evidence", match_method: MATCH_METHOD).exists?
      raise Conflict, "Lunch Flow posted match already has a different pending observation"
    end

    observation.assign_attributes(account: account, family: account.family, ingestion_batch: batch,
      pending: true, withdrawn: false, observation_order: metadata.fetch(:observation_order, []))
    if observation.new_record?
      observation.input_external_id = record[:external_id]
      observation.input_occurrence = metadata.fetch(:identity_occurrence, 0)
    end
    observation.save!
    observation.create_entry_source!(entry: entry, account: account, family: account.family,
      role: "evidence", match_method: MATCH_METHOD) unless retained
    true
  rescue ActiveRecord::RecordNotFound
    raise Conflict, "Lunch Flow posted match no longer exists", cause: nil
  end

  private
    attr_reader :external_account, :account, :batch

    def validate_policy!(record, metadata)
      policy = metadata[:posted_match_policy]
      expected = { source: "lunchflow", forward_days: 8, amount: "exact", currency: "exact",
        name: policy.is_a?(Hash) ? policy[:name] : nil, exclude_external_id_prefix: "lunchflow_pending_" }
      unless external_account.provider_key == "lunchflow" && batch.stream == "transactions" &&
          record.kind == "transaction" && record[:pending] == true &&
          record[:external_id].match?(/\Alunchflow_pending_[0-9a-f]{32}\z/) &&
          metadata[:identity_policy] == "reuse_pending_or_allocate_suffix" &&
          policy.is_a?(Hash) && [ nil, "exact" ].include?(policy[:name]) && policy == expected.with_indifferent_access
        raise Conflict, "Invalid Lunch Flow posted match policy"
      end
    end

    def posting_scope
      EntrySource.joins(:source_record, :entry).where(active: true, role: "posting",
        account_id: account.id, family_id: account.family_id,
        source_records: { external_account_id: external_account.id, account_id: account.id,
          family_id: account.family_id, kind: "transaction", pending: false, withdrawn: false },
        entries: { account_id: account.id, source: "lunchflow", entryable_type: "Transaction" })
        .where.not(entries: { external_id: nil })
        .where("entries.external_id NOT LIKE ?", "#{Entry.sanitize_sql_like('lunchflow_pending_')}%")
    end

    def verify_posting!(posting, entry)
      source = posting.source_record
      original_batch = source.ingestion_batch
      unless !entry.transaction.pending? && (original_batch.origin_kind == "migration" ||
          original_batch.applied? || original_batch.id == batch.id)
        raise Conflict, "Lunch Flow posted match has no completed publication"
      end
      resolved = Ingestion::MappedEntryResolver.new(external_account: external_account, account: account,
        definition: Provider::AccountData::Lunchflow.definition).resolve(source_record: source,
          kind: "transaction", external_id: source.external_id, entryable_type: "Transaction")
      unless resolved.resolved? && resolved.entry_identity == entry.id && resolved.entry_source_id == posting.id
        raise Conflict, "Lunch Flow posted match has no current source proof"
      end
    end
end
