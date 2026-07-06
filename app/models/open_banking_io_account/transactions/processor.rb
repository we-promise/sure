class OpenBankingIoAccount::Transactions::Processor
  attr_reader :open_banking_io_account

  def initialize(open_banking_io_account)
    @open_banking_io_account = open_banking_io_account
  end

  def process
    unless open_banking_io_account.raw_transactions_payload.present?
      Rails.logger.info "OpenBankingIoAccount::Transactions::Processor - No open-banking.io transactions available to process"
      pruned_count = prune_stale_pending_entries([])
      return { success: true, total: 0, imported: 0, failed: 0, pruned_pending: pruned_count, errors: [] }
    end

    total_count = open_banking_io_account.raw_transactions_payload.count
    imported_count = 0
    failed_count = 0
    errors = []
    current_pending_external_ids = pending_external_ids

    open_banking_io_account.raw_transactions_payload.each_with_index do |transaction_data, index|
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
    rescue => e
      failed_count += 1
      errors << { index: index, transaction_id: transaction_id(transaction_data), error: "#{e.class}: #{e.message}" }
      Rails.logger.error "OpenBankingIoAccount::Transactions::Processor - Error processing transaction #{transaction_id(transaction_data)}: #{e.class} - #{e.message}"
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

    def prune_stale_pending_entries(current_pending_external_ids)
      account = open_banking_io_account.current_account
      return 0 unless account.present?

      stale_pending_entries = account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(source: "open_banking_io")
        .where("(transactions.extra -> 'open_banking_io' ->> 'pending')::boolean = true")
      stale_pending_entries = stale_pending_entries.where.not(external_id: current_pending_external_ids) if current_pending_external_ids.any?

      count = stale_pending_entries.count
      stale_pending_entries.find_each(&:destroy!) if count.positive?
      count
    end
end
