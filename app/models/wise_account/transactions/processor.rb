# frozen_string_literal: true

class WiseAccount::Transactions::Processor
  attr_reader :wise_account

  def initialize(wise_account)
    @wise_account = wise_account
  end

  def process
    unless wise_account.raw_transactions_payload.present?
      Rails.logger.info "WiseAccount::Transactions::Processor - No transactions for wise_account #{wise_account.id}"
      return { success: true, total: 0, imported: 0, skipped: 0, failed: 0, errors: [] }
    end

    total = wise_account.raw_transactions_payload.count
    Rails.logger.info "WiseAccount::Transactions::Processor - Processing #{total} transactions for wise_account #{wise_account.id}"

    imported = 0
    failed = 0
    skipped = 0
    errors = []

    wise_account.raw_transactions_payload.each_with_index do |tx_data, index|
      # Activities (from the Wise activities API) carry a "type" field; transfers do not.
      processor_class = tx_data["type"].present? ? WiseActivity::Processor : WiseEntry::Processor
      result = processor_class.new(tx_data, wise_account: wise_account).process

      case result
      when :skipped
        skipped += 1
      when nil
        failed += 1
        errors << { index: index, error: "No transaction imported" }
      else
        imported += 1
      end
    rescue ArgumentError => e
      failed += 1
      Rails.logger.error "WiseAccount::Transactions::Processor - Validation error at index #{index}: #{e.message}"
      errors << { index: index, error: e.message }
    rescue => e
      failed += 1
      Rails.logger.error "WiseAccount::Transactions::Processor - Error at index #{index}: #{e.class} - #{e.message}"
      Rails.logger.error Array(e.backtrace).first(10).join("\n")
      errors << { index: index, error: "#{e.class}: #{e.message}" }
    end

    Rails.logger.info "WiseAccount::Transactions::Processor - Done: #{imported} imported, #{skipped} skipped, #{failed} failed"

    { success: failed == 0, total: total, imported: imported, skipped: skipped, failed: failed, errors: errors }
  end
end
