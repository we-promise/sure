class GocardlessAccount::Transactions::Processor
  attr_reader :gocardless_account

  def initialize(gocardless_account)
    @gocardless_account = gocardless_account
  end

  def process
    unless gocardless_account.raw_transactions_payload.present?
      Rails.logger.info "GocardlessAccount::Transactions::Processor - No transactions stored for gocardless_account #{gocardless_account.id}"
      return { success: true, total: 0, imported: 0, failed: 0 }
    end

    total_count = gocardless_account.raw_transactions_payload.count
    Rails.logger.info "GocardlessAccount::Transactions::Processor - Processing #{total_count} transaction(s) for gocardless_account #{gocardless_account.id}"

    imported_count = 0
    failed_count   = 0

    shared_adapter = if gocardless_account.current_account.present?
      Account::ProviderImportAdapter.new(gocardless_account.current_account)
    end

    gocardless_account.raw_transactions_payload.each_with_index do |txn_data, index|
      begin
        result = GocardlessEntry::Processor.new(
          txn_data,
          gocardless_account: gocardless_account,
          import_adapter:     shared_adapter
        ).process

        if result.nil?
          failed_count += 1
        else
          imported_count += 1
        end
      rescue ArgumentError => e
        failed_count += 1
        txn_id = txn_data.try(:[], "transactionId") || txn_data.try(:[], :transactionId) || index
        Rails.logger.error "GocardlessAccount::Transactions::Processor - Validation error at index #{index} (txn #{txn_id}): #{e.message}"
      rescue => e
        failed_count += 1
        txn_id = txn_data.try(:[], "transactionId") || txn_data.try(:[], :transactionId) || index
        Rails.logger.error "GocardlessAccount::Transactions::Processor - Error at index #{index} (txn #{txn_id}): #{e.class} - #{e.message}"
      end
    end

    if failed_count > 0
      Rails.logger.warn "GocardlessAccount::Transactions::Processor - Completed with #{failed_count} failure(s) out of #{total_count}"
    else
      Rails.logger.info "GocardlessAccount::Transactions::Processor - Successfully processed #{imported_count} transaction(s)"
    end

    { success: failed_count == 0, total: total_count, imported: imported_count, failed: failed_count }
  end
end
