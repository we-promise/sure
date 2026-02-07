# Processes raw transaction data to create Maybe Transaction records.
#
# This processor takes the raw transaction payload stored in a SophtronAccount
# and converts each transaction into a Maybe Transaction record using
# SophtronEntry::Processor. It processes transactions individually to avoid
# database lock issues when handling large transaction volumes.
#
# The processor is resilient to errors - if one transaction fails, it logs
# the error and continues processing the remaining transactions.
class SophtronAccount::Transactions::Processor
  attr_reader :sophtron_account

  # Initializes a new transaction processor.
  #
  # @param sophtron_account [SophtronAccount] The account whose transactions to process
  def initialize(sophtron_account)
    @sophtron_account = sophtron_account
  end

  # Processes all transactions in the raw_transactions_payload.
  #
  # Each transaction is processed individually to avoid database lock contention.
  # Errors are caught and logged, allowing the process to continue with remaining
  # transactions.
  #
  # @return [Hash] Processing results with the following keys:
  #   - :success [Boolean] true if all transactions processed successfully
  #   - :total [Integer] Total number of transactions found
  #   - :imported [Integer] Number of transactions successfully imported
  #   - :failed [Integer] Number of transactions that failed
  #   - :errors [Array<Hash>] Details of any errors encountered
  # @example
  #   result = processor.process
  #   # => { success: true, total: 100, imported: 98, failed: 2, errors: [...] }
  def process
    unless sophtron_account.raw_transactions_payload.present?
      Rails.logger.info "SophtronAccount::Transactions::Processor - No transactions in raw_transactions_payload for sophtron_account #{sophtron_account.id}"
      return { success: true, total: 0, imported: 0, failed: 0, errors: [] }
    end

    total_count = sophtron_account.raw_transactions_payload.count
    Rails.logger.info "SophtronAccount::Transactions::Processor - Processing #{total_count} transactions for sophtron_account #{sophtron_account.id}"

    imported_count = 0
    failed_count = 0
    errors = []

    # Each entry is processed inside a transaction, but to avoid locking up the DB when
    # there are hundreds or thousands of transactions, we process them individually.
    sophtron_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      begin
        result = SophtronEntry::Processor.new(
          transaction_data,
          sophtron_account: sophtron_account
        ).process

        if result.nil?
          # Transaction was skipped (e.g., no linked account)
          failed_count += 1
          errors << { index: index, transaction_id: transaction_data[:id], error: "No linked account" }
        else
          imported_count += 1
        end
      rescue ArgumentError => e
        # Validation error - log and continue
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "Validation error: #{e.message}"
        Rails.logger.error "SophtronAccount::Transactions::Processor - #{error_message} (transaction #{transaction_id})"
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      rescue => e
        # Unexpected error - log with full context and continue
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "#{e.class}: #{e.message}"
        Rails.logger.error "SophtronAccount::Transactions::Processor - Error processing transaction #{transaction_id}: #{error_message}"
        Rails.logger.error e.backtrace.join("\n")
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      end
    end

    result = {
      success: failed_count == 0,
      total: total_count,
      imported: imported_count,
      failed: failed_count,
      errors: errors
    }

    if failed_count > 0
      Rails.logger.warn "SophtronAccount::Transactions::Processor - Completed with #{failed_count} failures out of #{total_count} transactions"
    else
      Rails.logger.info "SophtronAccount::Transactions::Processor - Successfully processed #{imported_count} transactions"
    end

    result
  end
end
