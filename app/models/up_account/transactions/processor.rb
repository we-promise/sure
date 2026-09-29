class UpAccount::Transactions::Processor
  attr_reader :up_account

  # Build a transactions processor for the given +up_account+.
  def initialize(up_account)
    @up_account = up_account
  end

  # Process each stored raw transaction into a Sure entry, prune stale pending
  # entries, and return a stats hash (total/imported/failed/pruned/errors).
  def process
    unless up_account.raw_transactions_payload.present?
      Rails.logger.info "UpAccount::Transactions::Processor - No Up transactions available to process"
      pruned_count = prune_stale_pending_entries([])
      return { success: true, total: 0, imported: 0, failed: 0, pruned_pending: pruned_count, errors: [] }
    end

    total_count = up_account.raw_transactions_payload.count
    imported_count = 0
    failed_count = 0
    errors = []
    current_pending_external_ids = pending_external_ids

    up_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      result = UpEntry::Processor.new(
        transaction_data,
        up_account: up_account,
        category_matcher: category_matcher
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
      Rails.logger.error "UpAccount::Transactions::Processor - Validation error processing transaction #{transaction_id(transaction_data)}: #{e.message}"
    rescue => e
      failed_count += 1
      errors << { index: index, transaction_id: transaction_id(transaction_data), error: "#{e.class}: #{e.message}" }
      Rails.logger.error "UpAccount::Transactions::Processor - Error processing transaction #{transaction_id(transaction_data)}: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
    end
    pruned_count = prune_stale_pending_entries(current_pending_external_ids)

    {
      success: failed_count.zero?,
      total: total_count,
      imported: imported_count,
      failed: failed_count,
      pruned_pending: pruned_count,
      errors: errors
    }
  end

  private

    # A single category matcher reused across this account's transactions, built from
    # the family's existing categories.
    def category_matcher
      @category_matcher ||= UpAccount::Transactions::CategoryMatcher.new(family_categories)
    end

    # The family's existing categories. Importing transactions is intentionally
    # non-destructive with respect to the family's category structure: we do NOT
    # bootstrap Sure's defaults here. A family that has no categories (deliberately
    # cleared, or pre-onboarding) simply gets uncategorised transactions, and matching
    # resumes once the user sets up categories through the normal UI flow. Returns []
    # when the account isn't linked (each entry is skipped before the matcher is used).
    def family_categories
      @family_categories ||= up_account.current_account&.family&.categories&.to_a || []
    end

    # Extract the Up transaction id from raw data, or "unknown".
    def transaction_id(transaction_data)
      transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
    end

    # Canonical external ids of the currently-HELD (pending) transactions.
    def pending_external_ids
      up_account.raw_transactions_payload.filter_map do |transaction_data|
        next unless transaction_data.is_a?(Hash)
        next unless UpEntry::Processor.pending?(transaction_data)

        UpEntry::Processor.canonical_external_id(transaction_data)
      end
    end

    # Delete previously-imported pending entries no longer present in the latest
    # fetch (cancelled/settled holds), returning how many were removed.
    def prune_stale_pending_entries(current_pending_external_ids)
      account = up_account.current_account
      return 0 unless account.present?

      stale_pending_entries = account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(source: "up")
        .where("(transactions.extra -> 'up' ->> 'pending')::boolean = true")
      stale_pending_entries = stale_pending_entries.where.not(external_id: current_pending_external_ids) if current_pending_external_ids.any?

      count = stale_pending_entries.count
      stale_pending_entries.find_each(&:destroy!) if count.positive?
      count
    end
end
