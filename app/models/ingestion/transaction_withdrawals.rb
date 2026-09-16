# Explicit API tombstones withdraw source evidence. Deletion is permitted only
# for an identified posting owned by this source and without user protection or
# another live observation. Unknown legacy ledger identities require backfill.
class Ingestion::TransactionWithdrawals
  Withdrawal = Data.define(:observation, :entry)
  private_constant :Withdrawal

  def initialize(external_account:, batch:, source:)
    @external_account, @batch, @source = external_account, batch, source
    @account = external_account.current_account
  end

  def apply(ids, authoritative:)
    SourceRecord.transaction do
      # Resolve every identity before withdrawing any of them. A pending alias
      # and its current posting may occur in either order in one removal set.
      withdrawals = ids.uniq.map { |id| prepare(id, authoritative: authoritative) }
      withdrawals.each do |withdrawal|
        withdrawal.observation.update!(account: @account, family: @account.family,
          ingestion_batch: @batch, pending: false, withdrawn: true)
      end
      withdrawals.filter_map(&:entry).uniq(&:id).each { |entry| withdraw_posting(entry) }
    end
  end

  private
    def prepare(external_id, authoritative:)
      observation = SourceRecord.find_or_initialize_by(external_account: @external_account, kind: "transaction", external_id: external_id)
      entry = observation.entry
      if entry
        entry.lock!
        entry.entryable&.lock!
      elsif @account.entries.exists?(source: @source, external_id: external_id) ||
          (@source == "plaid" && @account.entries.exists?(plaid_id: external_id))
        raise Provider::AccountData::InvalidResponse, "Removal needs migrated financial evidence"
      end

      current_posting = nil
      if authoritative && entry && observation.entry_source&.role == "posting" && !observation.withdrawn?
        resolution = resolver.resolve(source_record: observation, kind: "transaction", external_id: external_id, entryable_type: "Transaction")
        # A retired pending alias describes the old observation. It cannot
        # authorize a change to the financial entry now owned by the posted ID.
        # The resolver also checks immutable bootstrap aliases that were proved
        # only by an archive and were never copied into Transaction#extra.
        current_posting = entry if resolution.resolved?
      end
      Withdrawal.new(observation: observation, entry: current_posting)
    end

    def resolver
      @resolver ||= Ingestion::MappedEntryResolver.new(external_account: @external_account, account: @account,
        definition: Provider::AccountData::Registry.fetch(@external_account.provider_key).definition)
    end

    def withdraw_posting(entry)
      if entry.protected_from_sync? || entry.reconciled? || entry.locked_field_names.any? ||
          retained_financial_context?(entry) || live_evidence?(entry)
        return if entry.transaction.locked?(:extra)
        data = entry.transaction.extra.deep_dup
        if data[@source].is_a?(Hash) && data[@source]["pending"] == true
          data[@source]["pending"] = false
          entry.transaction.update!(extra: data)
        end
      else
        entry.destroy!
      end
    end

    def retained_financial_context?(entry)
      # Source absence withdraws its observation, not the user's surrounding
      # financial graph. Destroying a transfer leg can also destroy fee entries;
      # destroying a split parent cascades to its children. Check raw fee FKs as
      # well as leg references because Transaction#transfer only resolves legs.
      transaction = entry.transaction
      return true if entry.parent_entry_id || transaction.transfer_id || transaction.transfer?
      return true if entry.child_entries.exists? || transaction.attachments.attached?
      return true if Transfer.where(inflow_transaction_id: transaction.id).or(Transfer.where(outflow_transaction_id: transaction.id)).exists?
      return true if RejectedTransfer.where(inflow_transaction_id: transaction.id).or(RejectedTransfer.where(outflow_transaction_id: transaction.id)).exists?
      return true if GoalPledge.where(matched_transaction_id: transaction.id).exists? || entry.recurring_allocations.exists?
      return true if RecurringMatchRejection.where(entry_id: entry.id).exists? || RecurringPriceChange.where(entry_id: entry.id).exists?

      # Entryable's reverse destroy callback must not remove a second posting
      # that this source's exact identity resolution never authorized.
      Entry.where(entryable_type: "Transaction", entryable_id: transaction.id).where.not(id: entry.id).exists?
    end

    def live_evidence?(entry)
      EntrySource.joins(:source_record).includes(:source_record)
        .where(entry: entry, active: true, source_records: { withdrawn: false }).find_each.any? do |mapping|
          observation = mapping.source_record
          next true unless mapping.role == "posting" && observation.external_account_id == @external_account.id && observation.kind == "transaction"

          # An old same-source pending assertion is not independent evidence for
          # the current posting, even if its tombstone arrives in a later page.
          !resolver.resolve(source_record: observation, kind: "transaction", external_id: observation.external_id,
            entryable_type: "Transaction").retired_alias?
        end
    end
end
