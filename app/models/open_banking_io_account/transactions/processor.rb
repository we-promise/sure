class OpenBankingIoAccount::Transactions::Processor
  attr_reader :open_banking_io_account

  def initialize(open_banking_io_account)
    @open_banking_io_account = open_banking_io_account
  end

  def process
    unless open_banking_io_account.raw_transactions_payload.present?
      # Prune nothing here. An absent payload is indistinguishable from a transient empty
      # response, and prune_stale_pending_entries([]) has no "keep" list to narrow by -- it
      # would destroy every pending entry on the account, and every user edit with it.
      Rails.logger.info "OpenBankingIoAccount::Transactions::Processor - No open-banking.io transactions available to process"
      return { success: true, total: 0, imported: 0, failed: 0, pruned_pending: 0, errors: [] }
    end

    total_count = open_banking_io_account.raw_transactions_payload.count
    imported_count = 0
    skipped_count = 0
    failed_count = 0
    errors = []
    current_pending_external_ids = pending_external_ids
    excluded_ids = excluded_external_ids

    discarded_external_ids = []

    ordered_transactions(open_banking_io_account.raw_transactions_payload).each_with_index do |transaction_data, index|
      ext_id = OpenBankingIoEntry::Processor.canonical_external_id(transaction_data)
      if OpenBankingIoEntry::Processor.skip?(transaction_data)
        # Cancelled, rejected or future-dated: not money that moved. If we imported it
        # while it was still BOOK, it has to come back out -- skipping alone would leave it
        # in the ledger permanently, affecting the balance, with no path to remove it.
        discarded_external_ids << ext_id if ext_id.present?
        skipped_count += 1
        next
      end

      if ext_id.present? && excluded_ids.include?(ext_id)
        # This pending row was already reconciled into a booked transaction
        # (auto-claimed by the amount/date heuristic, or manually merged by the
        # user). The stored raw payload still contains the old pending data, so
        # skip it to avoid recreating a phantom pending duplicate.
        Rails.logger.info "OpenBankingIoAccount::Transactions::Processor - Skipping already-reconciled pending transaction #{ext_id}"
        skipped_count += 1
        next
      end

      result = OpenBankingIoEntry::Processor.new(
        transaction_data,
        open_banking_io_account: open_banking_io_account
      ).process

      if result.nil?
        failed_count += 1
        errors << { index: index, transaction_id: transaction_id(transaction_data), error: "No linked account" }
      else
        imported_count += 1
      end
    rescue ArgumentError => e
      failed_count += 1
      errors << { index: index, transaction_id: transaction_id(transaction_data), error: "Validation error: #{e.message}" }
      Rails.logger.error "OpenBankingIoAccount::Transactions::Processor - Validation error processing transaction #{transaction_id(transaction_data)}: #{e.message}"
      capture_row_error(e, transaction_data)
    rescue => e
      failed_count += 1
      errors << { index: index, transaction_id: transaction_id(transaction_data), error: "#{e.class}: #{e.message}" }
      Rails.logger.error "OpenBankingIoAccount::Transactions::Processor - Error processing transaction #{transaction_id(transaction_data)}: #{e.class} - #{e.message}"
      capture_row_error(e, transaction_data)
    end
    pruned_count = prune_stale_pending_entries(current_pending_external_ids)
    pruned_count += prune_discarded_entries(discarded_external_ids)

    {
      success: failed_count.zero?,
      total: total_count,
      imported: imported_count,
      skipped: skipped_count,
      failed: failed_count,
      pruned_pending: pruned_count,
      errors: errors
    }
  end

  private

    # Process PENDING rows before BOOKED ones within a single sync.
    #
    # Pending→booked reconciliation is driven from the BOOKED side: a booked
    # transaction auto-claims a matching pending entry that is ALREADY persisted
    # (Account::ProviderImportAdapter#find_pending_transaction). When a booked
    # row and its still-listed pending sibling (different ids, same amount) arrive
    # in the SAME fetch, the pending sibling must be imported first so the booked
    # settlement can find and claim it; otherwise the booked row is processed with
    # no pending to claim and the pending row then imports as a phantom duplicate.
    # A stable sort preserves the bank's relative ordering within each group.
    def ordered_transactions(transactions)
      transactions.each_with_index
                  .sort_by { |transaction_data, index| [ OpenBankingIoEntry::Processor.pending?(transaction_data) ? 0 : 1, index ] }
                  .map(&:first)
    end

    # External ids that must NOT be re-imported this sync because the pending
    # transaction they represent has already been reconciled into a booked one.
    # Mirrors EnableBankingAccount::Transactions::Processor: one query per
    # category, O(1) Set membership per transaction (no N+1).
    def excluded_external_ids
      account = open_banking_io_account.current_account
      return Set.new unless account.present?

      account_id = account.id

      # 1. Manually merged: pending entries the user explicitly merged into a
      #    posted transaction. Handles both the current Array format and the
      #    legacy Hash format of the manual_merge metadata.
      manually_merged_ids = Transaction.joins(:entry)
                                       .where(entries: { account_id: account_id })
                                       .where("transactions.extra ? 'manual_merge'")
                                       .joins(
                                         Arel.sql(<<~SQL.squish)
                                           CROSS JOIN LATERAL jsonb_array_elements(
                                             CASE jsonb_typeof(transactions.extra->'manual_merge')
                                             WHEN 'array'  THEN transactions.extra->'manual_merge'
                                             WHEN 'object' THEN jsonb_build_array(transactions.extra->'manual_merge')
                                             ELSE '[]'::jsonb
                                             END
                                           ) AS merge_elem
                                         SQL
                                       )
                                       .pluck(Arel.sql("merge_elem->>'merged_from_external_id'"))
                                       .compact
                                       .to_set

      # 2. Auto-claimed: pending entries automatically matched to a booked
      #    transaction by the amount/date heuristic. Their old external_ids are
      #    stored in extra["auto_claimed_pending_ids"].
      auto_claimed_ids = Transaction.joins(:entry)
                                    .where(entries: { account_id: account_id })
                                    .where("transactions.extra ? 'auto_claimed_pending_ids'")
                                    .joins(
                                      Arel.sql(<<~SQL.squish)
                                        CROSS JOIN LATERAL jsonb_array_elements_text(
                                          transactions.extra->'auto_claimed_pending_ids'
                                        ) AS claimed_id
                                      SQL
                                    )
                                    .pluck(Arel.sql("claimed_id"))
                                    .compact
                                    .to_set

      manually_merged_ids | auto_claimed_ids
    end

    def transaction_id(transaction_data)
      transaction_data.try(:[], :id) ||
        transaction_data.try(:[], "id") ||
        "unknown"
    end

    def pending_external_ids
      open_banking_io_account.raw_transactions_payload.filter_map do |transaction_data|
        next unless transaction_data.is_a?(Hash)
        next unless OpenBankingIoEntry::Processor.pending?(transaction_data)

        OpenBankingIoEntry::Processor.canonical_external_id(transaction_data)
      end
    end

    # Removes entries for rows the bank has since marked cancelled, rejected or scheduled.
    # Scoped to this provider and to ids we just saw in the payload, so it can only ever
    # remove something we ourselves imported.
    # The result this row's error lands in is replaced by a generic message one layer up, so
    # without this /settings/debug shows "account processing failed" and nothing else.
    def capture_row_error(error, transaction_data)
      open_banking_io_account.open_banking_io_item&.capture_provider_error(
        "Failed to process an open-banking.io transaction",
        error: error,
        open_banking_io_account_id: open_banking_io_account.id,
        account_provider: open_banking_io_account.account_provider,
        provider_transaction_id: transaction_id(transaction_data)
      )
    end

    def prune_discarded_entries(discarded_external_ids)
      return 0 if discarded_external_ids.empty?

      account = open_banking_io_account.current_account
      return 0 unless account.present?

      entries = account.entries.where(source: "open_banking_io", external_id: discarded_external_ids)
      count = entries.count
      entries.find_each(&:destroy!) if count.positive?
      count
    end

    # A pending authorisation the bank never resolves would otherwise live forever: the
    # keep-list protects it every sync, and its presence pins the lookback open. No real
    # pre-auth outlives this, so anything older is stale regardless of the keep-list.
    MAX_PENDING_AGE = 60.days

    def prune_stale_pending_entries(current_pending_external_ids)
      account = open_banking_io_account.current_account
      return 0 unless account.present?

      pending_entries = account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(source: "open_banking_io")
        .where("(transactions.extra -> 'open_banking_io' ->> 'pending')::boolean = true")

      # The age grace applies in BOTH branches. With the corrected classifier most banks
      # never produce a pending row at all, so "payload present, zero pendings in it" is now
      # the normal case -- and pruning unconditionally there would destroy any pending entry
      # that has not yet auto-claimed, along with its category, merchant, notes and splits.
      cutoff = MAX_PENDING_AGE.ago.to_date
      stale_pending_entries =
        if current_pending_external_ids.any?
          pending_entries.where.not(external_id: current_pending_external_ids)
                         .or(pending_entries.where(date: ...cutoff))
        else
          pending_entries.where(date: ...cutoff)
        end

      count = stale_pending_entries.count
      stale_pending_entries.find_each(&:destroy!) if count.positive?
      count
    end
end
