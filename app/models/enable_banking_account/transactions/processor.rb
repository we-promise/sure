require "digest/md5"

class EnableBankingAccount::Transactions::Processor
  attr_reader :enable_banking_account

  def initialize(enable_banking_account)
    @enable_banking_account = enable_banking_account
  end

  def process
    unless enable_banking_account.raw_transactions_payload.present?
      Rails.logger.info "EnableBankingAccount::Transactions::Processor - No transactions in raw_transactions_payload for enable_banking_account #{enable_banking_account.id}"
      return { success: true, total: 0, imported: 0, failed: 0, errors: [] }
    end

    total_count = enable_banking_account.raw_transactions_payload.count
    Rails.logger.info "EnableBankingAccount::Transactions::Processor - Processing #{total_count} transactions for enable_banking_account #{enable_banking_account.id}"

    imported_count = 0
    skipped_count = 0
    failed_count = 0
    errors = []

    shared_adapter = if enable_banking_account.current_account.present?
      Account::ProviderImportAdapter.new(enable_banking_account.current_account)
    end

    # Fetch once per sync batch rather than once per transaction (each row gets its
    # own Processor instance below) -- avoids repeating the same family-scoped
    # merchant queries for every imported row.
    shared_known_merchant_names = enable_banking_account.current_account&.family&.known_merchant_names || []

    # Pre-fetch external_ids that must not be re-imported.
    # One query per category per sync; O(1) Set lookup per transaction — avoids N+1.
    excluded_ids = if enable_banking_account.current_account
      account_id = enable_banking_account.current_account.id

      # 1. Manually merged: pending entries the user explicitly merged into a posted transaction.
      #    Uses a lateral join to extract merged_from_external_id from the manual_merge JSON
      #    (handles both Array current format and legacy Hash format via jsonb_typeof).
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

      # 2. Auto-claimed: pending entries that were automatically matched to a booked transaction
      #    by the amount/date heuristic. Their old external_ids are stored in
      #    extra["auto_claimed_pending_ids"] so they are not re-imported as new pending entries
      #    on subsequent syncs (the stored raw payload still contains the old pending data).
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
    else
      Set.new
    end

    # A row without a provider id hashes to its content, and within one response
    # two such rows can share that hash. Each such row gets a suffix that tells
    # it apart, worked out over the whole batch before any row is imported.
    identities = content_identities(enable_banking_account.raw_transactions_payload, excluded_ids)

    enable_banking_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      begin
        id_suffix, fingerprint = identities[index]
        ext_id = EnableBankingEntry::Processor.compute_external_id(transaction_data, suffix: id_suffix)

        if ext_id && excluded_ids.include?(ext_id)
          Rails.logger.info("EnableBankingAccount::Transactions::Processor - Skipping re-import of manually merged pending transaction: #{ext_id}")
          skipped_count += 1
          next
        end

        result = EnableBankingEntry::Processor.new(
          transaction_data,
          enable_banking_account: enable_banking_account,
          import_adapter: shared_adapter,
          known_merchant_names: shared_known_merchant_names,
          id_suffix: id_suffix,
          content_fingerprint: fingerprint
        ).process

        if result.nil?
          failed_count += 1
          errors << { index: index, transaction_id: transaction_data[:transaction_id], error: "No linked account" }
        else
          imported_count += 1
        end
      rescue ArgumentError => e
        failed_count += 1
        transaction_id = transaction_data.try(:[], :transaction_id) || transaction_data.try(:[], "transaction_id") || "unknown"
        error_message = "Validation error: #{e.message}"
        Rails.logger.error "EnableBankingAccount::Transactions::Processor - #{error_message} (transaction #{transaction_id})"
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      rescue => e
        failed_count += 1
        transaction_id = transaction_data.try(:[], :transaction_id) || transaction_data.try(:[], "transaction_id") || "unknown"
        error_message = "#{e.class}: #{e.message}"
        Rails.logger.error "EnableBankingAccount::Transactions::Processor - Error processing transaction #{transaction_id}: #{error_message}"
        Rails.logger.error e.backtrace.join("\n")
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      end
    end

    result = {
      success: failed_count == 0,
      total: total_count,
      imported: imported_count,
      skipped: skipped_count,
      failed: failed_count,
      errors: errors
    }

    if failed_count > 0
      Rails.logger.warn "EnableBankingAccount::Transactions::Processor - Completed with #{failed_count} failures out of #{total_count} transactions"
    else
      Rails.logger.info "EnableBankingAccount::Transactions::Processor - Successfully processed #{imported_count} transactions"
    end

    result
  end

  private

    # For each row, [suffix, fingerprint]: the suffix that tells an id-less row
    # apart from the other rows of the batch that hash to the same content (nil
    # when none is needed), and the full-content fingerprint recorded on it.
    # [nil, nil] for a row with a provider id or with nothing to hash.
    #
    # A suffix has to be an identity, not a position: the next response may
    # order the rows differently, carry only one of them, or add a third. So
    # the identities a group already has -- in the ledger, or among the ids
    # excluded because they were merged away -- are resolved first, and only
    # what is left is given a new one:
    #
    # - a member whose full-content id is already known keeps it;
    # - a bare-form id already known (the hash alone, or numbered) goes to the
    #   member whose recorded fingerprint it carries; when the entry is older
    #   than fingerprints, to the only member, or to any of a set of identical
    #   members, which are interchangeable; if that cannot be told, it is left
    #   alone, and the row imports under its own id -- one visible duplicate
    #   rather than a silent update of the wrong transaction;
    # - the rest: rows identical in every field are numbered from the bare hash,
    #   the first keeping it bare; rows that differ in a field the hash does not
    #   read each take a hash of their full content.
    def content_identities(rows, excluded_ids)
      bases = rows.map { |row| EnableBankingEntry::Processor.compute_external_id(row) rescue nil }
      fulls = rows.map { |row| EnableBankingEntry::Processor.content_fingerprint(row) }

      groups = Hash.new { |h, k| h[k] = [] }
      bases.each_with_index { |base, i| groups[base] << i if base&.start_with?("enable_banking_content_") }
      return Array.new(rows.size) { [ nil, nil ] } if groups.empty?

      known = known_identities(groups.keys)
      excluded = excluded_ids.to_set

      ids = {}
      ambiguous = []
      groups.each do |base, members|
        ranks = {}
        members.sort_by { |i| [ fulls[i], i ] }.group_by { |i| fulls[i] }.each_value do |same|
          same.each_with_index { |i, rank| ranks[i] = rank }
        end
        full_id = ->(i) { ranks[i].zero? ? "#{base}_#{fulls[i]}" : "#{base}_#{fulls[i]}_#{ranks[i]}" }
        bare_id = ->(i) { ranks[i].zero? ? base : "#{base}_#{ranks[i]}" }
        taken = ->(id) { known.key?(id) || excluded.include?(id) }

        # 1. Full-content identities already known.
        members.each { |i| ids[i] = full_id.call(i) if taken.call(full_id.call(i)) }

        # 2. Bare-form identities already known, claimed by fingerprint or when unambiguous.
        members.reject { |i| ids.key?(i) }.group_by { |i| bare_id.call(i) }.each do |id, holders|
          next unless taken.call(id)
          next if ids.value?(id)

          fingerprint = known[id]
          owner = if fingerprint.present?
            holders.find { |i| fulls[i] == fingerprint }
          elsif holders.map { |i| fulls[i] }.uniq.size == 1
            holders.first
          end
          ids[owner] = id if owner
          ambiguous << id if owner.nil? && fingerprint.blank?
        end

        # 3. New identities for what is left, by the shape of the group. A bare
        #    id that is already taken, and was not claimed above, belongs to a
        #    different row; the newcomer takes its own full-content id instead
        #    of overwriting that transaction, or of being skipped as it.
        remaining = members.reject { |i| ids.key?(i) }
        identical = members.map { |i| fulls[i] }.uniq.size == 1
        remaining.each do |i|
          candidate = identical || members.size == 1 ? bare_id.call(i) : full_id.call(i)
          candidate = full_id.call(i) if candidate == bare_id.call(i) && (taken.call(candidate) || ids.value?(candidate))
          ids[i] = candidate
        end
      end

      report_ambiguous_identities(ambiguous) if ambiguous.any?

      rows.each_index.map do |i|
        next [ nil, nil ] unless ids.key?(i)

        id = ids[i]
        suffix = id == bases[i] ? nil : id.delete_prefix("#{bases[i]}_")
        [ suffix, fulls[i] ]
      end
    end

    # An entry from before fingerprints were recorded, whose content hash is now
    # shared by rows that differ: which of them it was made from cannot be
    # told, so it is left as it is and the rows import under their own ids.
    # That leaves the account one visible duplicate, which support may be asked
    # about, so it is recorded.
    def report_ambiguous_identities(external_ids)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Enable Banking id-less entry could not be matched to one of several rows sharing its content hash; " \
                 "kept as is, and the rows were imported under their own ids",
        source: self.class.name,
        provider_key: "enable_banking",
        account_provider: enable_banking_account.account_provider,
        family: enable_banking_account.enable_banking_item&.family,
        metadata: { external_ids: external_ids }
      )
    end

    # The ids the ledger already holds for these content hashes, bare or
    # suffixed, with the fingerprint recorded on each where there is one.
    def known_identities(bases)
      account = enable_banking_account.current_account
      return {} unless account

      patterns = bases.map { |base| "#{base.gsub(/[\\%_]/) { |c| "\\#{c}" }}\\_%" }
      account.entries
             .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
             .where(source: "enable_banking")
             .where("entries.external_id = ANY(ARRAY[?]::text[]) OR entries.external_id LIKE ANY(ARRAY[?]::text[])", bases, patterns)
             .pluck(:external_id, Arel.sql("transactions.extra -> 'enable_banking' ->> 'content_fingerprint'"))
             .to_h
    end
end
