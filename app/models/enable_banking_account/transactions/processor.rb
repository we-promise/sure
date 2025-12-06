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
    failed_count = 0
    errors = []

    enable_banking_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      begin
        result = EnableBankingEntry::Processor.new(
          transaction_data,
          enable_banking_account: enable_banking_account
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
end
