# frozen_string_literal: true

class FioAccount::Transactions::Processor
  attr_reader :fio_account

  def initialize(fio_account)
    @fio_account = fio_account
  end

  # Process each stored movement into a Sure entry and return a stats hash. The whole
  # stored payload is replayed every sync: entries are matched on Fio's movement id, so
  # re-processing a movement updates the entry it already produced.
  def process
    transactions = fio_account.raw_transactions_payload.to_a

    if transactions.empty?
      Rails.logger.info "FioAccount::Transactions::Processor - No Fio movements available to process"
      return { success: true, total: 0, imported: 0, skipped: 0, failed: 0, errors: [] }
    end

    imported_count = 0
    skipped_count = 0
    failed_count = 0
    errors = []

    transactions.each_with_index do |transaction_data, index|
      result = FioEntry::Processor.new(transaction_data, fio_account: fio_account).process

      if result.nil?
        # A movement the entry processor declined: no usable amount or date. Counting it
        # as a failure would fail every sync from here on, because the stored payload is
        # replayed in full each time and one unusable movement never becomes usable.
        skipped_count += 1
        Rails.logger.warn "FioAccount::Transactions::Processor - Skipped movement #{transaction_id(transaction_data)}"
      else
        imported_count += 1
      end
    rescue ArgumentError => e
      failed_count += 1
      errors << { index: index, transaction_id: transaction_id(transaction_data), error: "Validation error: #{e.message}" }
      Rails.logger.error "FioAccount::Transactions::Processor - Validation error processing movement #{transaction_id(transaction_data)}: #{e.message}"
    rescue => e
      failed_count += 1
      errors << { index: index, transaction_id: transaction_id(transaction_data), error: "#{e.class}: #{e.message}" }
      Rails.logger.error "FioAccount::Transactions::Processor - Error processing movement #{transaction_id(transaction_data)}: #{e.class} - #{e.message}"
    end

    {
      success: failed_count.zero?,
      total: transactions.size,
      imported: imported_count,
      skipped: skipped_count,
      failed: failed_count,
      errors: errors
    }
  end

  private

    def transaction_id(transaction_data)
      FioEntry::Processor.canonical_external_id(transaction_data) || "unknown"
    end
end
