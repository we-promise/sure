# frozen_string_literal: true

class WiseAccount::Transactions::Processor
  attr_reader :wise_account, :import_complete

  # import_complete: see WiseItem#process_accounts.
  def initialize(wise_account, import_complete: false)
    @wise_account = wise_account
    @import_complete = import_complete
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
      result = processor_for(tx_data).process

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

  private

    def processor_for(tx_data)
      if WiseActivity::Processor::JAR_ACTIVITY_TYPES.include?(tx_data["type"])
        WiseActivity::Processor.new(tx_data, wise_account: wise_account)
      elsif tx_data["wise_statement"].present?
        WiseStatement::Processor.new(tx_data, wise_account: wise_account)
      else
        WiseEntry::Processor.new(tx_data, wise_account: wise_account, own_recipient_ids: own_recipient_ids,
                                          recipient_owners: recipient_owners)
      end
    end

    # Looked up once per run rather than once per transfer.
    def own_recipient_ids
      @own_recipient_ids ||= wise_account.wise_item.own_recipient_ids
    end

    def recipient_owners
      @recipient_owners ||= wise_account.wise_item.balance_recipient_owners
    end
end
