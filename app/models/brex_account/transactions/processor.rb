class BrexAccount::Transactions::Processor
  attr_reader :brex_account

  def initialize(brex_account)
    @brex_account = brex_account
  end

  def process
    unless brex_account.raw_transactions_payload.present?
      Rails.logger.info "BrexAccount::Transactions::Processor - No transactions in raw_transactions_payload for brex_account #{brex_account.id}"
      return { success: true, total: 0, imported: 0, skipped: 0, failed: 0, errors: [], skipped_transactions: [] }
    end

    total_count = brex_account.raw_transactions_payload.count
    Rails.logger.info "BrexAccount::Transactions::Processor - Processing #{total_count} transactions for brex_account #{brex_account.id}"

    imported_count = 0
    failed_count = 0
    skipped_count = 0
    errors = []
    skipped = []

    # Each entry is processed inside a transaction, but to avoid locking up the DB when
    # there are hundreds or thousands of transactions, we process them individually.
    brex_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      begin
        result = BrexEntry::Processor.new(
          transaction_data,
          brex_account: brex_account
        ).process

        if result == :skipped
          skipped_count += 1
          skipped << { index: index, transaction_id: transaction_id_for(transaction_data), reason: "No linked account" }
        elsif result.nil?
          failed_count += 1
          errors << { index: index, transaction_id: transaction_id_for(transaction_data), error: "No transaction imported" }
        else
          imported_count += 1
        end
      rescue ArgumentError => e
        # Validation error - log and continue
        failed_count += 1
        transaction_id = transaction_id_for(transaction_data)
        error_message = "Validation error: #{e.message}"
        Rails.logger.error "BrexAccount::Transactions::Processor - #{error_message} (transaction #{transaction_id})"
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      rescue => e
        # Unexpected error - log with full context and continue
        failed_count += 1
        transaction_id = transaction_id_for(transaction_data)
        error_message = "#{e.class}: #{e.message}"
        Rails.logger.error "BrexAccount::Transactions::Processor - Error processing transaction #{transaction_id}: #{error_message}"
        Rails.logger.error Array(e.backtrace).first(10).join("\n")
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      end
    end

    result = {
      success: failed_count == 0,
      total: total_count,
      imported: imported_count,
      skipped: skipped_count,
      failed: failed_count,
      errors: errors,
      skipped_transactions: skipped
    }

    if failed_count > 0
      Rails.logger.warn "BrexAccount::Transactions::Processor - Completed with #{failed_count} failures out of #{total_count} transactions"
    else
      Rails.logger.info "BrexAccount::Transactions::Processor - Successfully processed #{imported_count} transactions"
    end

    result
  end

  private

    def transaction_id_for(transaction_data)
      transaction_data&.dig(:id) || transaction_data&.dig("id") || "unknown"
    end
end
