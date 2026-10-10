class AkahuAccount::Transactions::Processor
  attr_reader :akahu_account

  def initialize(akahu_account)
    @akahu_account = akahu_account
  end

  def process
    unless akahu_account.raw_transactions_payload.present?
      Rails.logger.info "AkahuAccount::Transactions::Processor - No Akahu transactions available to process"
      pruned_count = prune_stale_pending_entries([])
      return { success: true, total: 0, imported: 0, failed: 0, pruned_pending: pruned_count, errors: [] }
    end

    total_count = akahu_account.raw_transactions_payload.count
    imported_count = 0
    failed_count = 0
    errors = []
    current_pending_external_ids = pending_external_ids

    akahu_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      result = AkahuEntry::Processor.new(
        transaction_data,
        akahu_account: akahu_account
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
      Rails.logger.error "AkahuAccount::Transactions::Processor - Validation error processing transaction #{transaction_id(transaction_data)}: #{e.message}"
    rescue => e
      failed_count += 1
      errors << { index: index, transaction_id: transaction_id(transaction_data), error: "#{e.class}: #{e.message}" }
      Rails.logger.error "AkahuAccount::Transactions::Processor - Error processing transaction #{transaction_id(transaction_data)}: #{e.class} - #{e.message}"
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

    def transaction_id(transaction_data)
      transaction_data.try(:[], :_id) ||
        transaction_data.try(:[], "_id") ||
        transaction_data.try(:[], :id) ||
        transaction_data.try(:[], "id") ||
        "unknown"
    end

    def pending_external_ids
      akahu_account.raw_transactions_payload.filter_map do |transaction_data|
        next unless transaction_data.is_a?(Hash)
        next unless AkahuEntry::Processor.pending?(transaction_data)

        AkahuEntry::Processor.canonical_external_id(transaction_data)
      end
    end

    def prune_stale_pending_entries(current_pending_external_ids)
      account = akahu_account.current_account
      return 0 unless account.present?

      stale_pending_entries = account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(source: "akahu")
        .where("(transactions.extra -> 'akahu' ->> 'pending')::boolean = true")
        # Never prune split parents or children: a split parent keeps its own pending
        # flag and is excluded, so without this guard destroy! would cascade
        # (dependent: :destroy) to the user's split children and silently wipe their
        # manual split. Children inherit the pending flag but are not authoritative.
        .excluding_split_parents
        .excluding_split_children
      stale_pending_entries = stale_pending_entries.where.not(external_id: current_pending_external_ids) if current_pending_external_ids.any?

      count = stale_pending_entries.count
      stale_pending_entries.find_each(&:destroy!) if count.positive?
      count
    end
end
