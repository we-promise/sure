# frozen_string_literal: true

require "digest"

class RedbarkAccount::Transactions::Processor
  include RedbarkAccount::DataHelpers

  attr_reader :redbark_account

  def initialize(redbark_account)
    @redbark_account = redbark_account
  end

  def process
    unless redbark_account.raw_transactions_payload.present?
      Rails.logger.info "RedbarkAccount::Transactions::Processor - No transactions in raw_transactions_payload for redbark_account #{redbark_account.id}"
      return { success: true, total: 0, imported: 0, skipped: 0, failed: 0, errors: [] }
    end

    total_count = redbark_account.raw_transactions_payload.count
    Rails.logger.info "RedbarkAccount::Transactions::Processor - Processing #{total_count} transactions for redbark_account #{redbark_account.id}"

    imported_count = 0
    skipped_count = 0
    failed_count = 0
    errors = []

    # Each entry is processed inside a transaction, but to avoid locking up the DB when
    # there are hundreds or thousands of transactions, we process them individually.
    redbark_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      begin
        result = process_transaction(transaction_data)

        if result.nil?
          # Benign skip (no linked account, blank id, unparseable amount/date)
          skipped_count += 1
        else
          imported_count += 1
        end
      rescue ArgumentError => e
        # Validation error - log and continue
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "Validation error: #{e.message}"
        Rails.logger.error "RedbarkAccount::Transactions::Processor - #{error_message} (transaction #{transaction_id})"
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      rescue => e
        # Unexpected error - log with full context and continue
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "#{e.class}: #{e.message}"
        Rails.logger.error "RedbarkAccount::Transactions::Processor - Error processing transaction #{transaction_id}: #{error_message}"
        Rails.logger.error e.backtrace.join("\n")
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      end
    end

    result = {
      success: failed_count == 0,
      total: total_count,
      imported: imported_count,
      skipped: skipped_count,
      failed: failed_count,
      errors: errors
    }

    if failed_count > 0 || skipped_count > 0
      DebugLogEntry.capture(
        category: "provider_sync",
        level: failed_count > 0 ? "warn" : "info",
        message: "Redbark transaction processing completed with skipped or failed rows",
        source: self.class.name,
        provider_key: "redbark",
        family: redbark_account.redbark_item.family,
        metadata: { redbark_account_id: redbark_account.id, total: total_count, imported: imported_count, skipped: skipped_count, failed: failed_count, errors: errors.first(10) }
      )
    end

    if failed_count > 0
      Rails.logger.warn "RedbarkAccount::Transactions::Processor - Completed with #{failed_count} failures out of #{total_count} transactions"
    else
      Rails.logger.info "RedbarkAccount::Transactions::Processor - Successfully processed #{imported_count} transactions (#{skipped_count} skipped)"
    end

    result
  end

  private

    def account
      @redbark_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    # Redbark transaction shape:
    # { id, accountId, accountName, status, date, datetime, postDate, description,
    #   amount, direction, category, merchantName, merchantCategoryCode }
    def process_transaction(transaction_data)
      return nil unless account.present?

      data = transaction_data.with_indifferent_access

      redbark_id = data[:id].to_s
      return nil if redbark_id.blank?

      external_id = "redbark_#{redbark_id}"

      amount = parse_transaction_amount(data)
      return nil if amount.nil?

      date = parse_date(data[:date] || data[:postDate])
      return nil if date.nil?

      name = data[:merchantName].presence || data[:description].presence || "Transaction"
      # Transactions carry no per-item currency; they are in the account's currency
      currency = account.currency

      extra = build_extra_metadata(data)

      Rails.logger.debug "RedbarkAccount::Transactions::Processor - Importing transaction: id=#{external_id} date=#{date}"

      # Use ProviderImportAdapter for proper deduplication via external_id + source
      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: name[0..254], # Limit to 255 chars
        source: "redbark",
        merchant: merchant_for(data),
        notes: data[:description].presence,
        extra: extra
      )
    end

    def parse_transaction_amount(data)
      amount = parse_decimal(data[:amount])
      return nil if amount.nil?

      # Redbark returns CDR pre-signed amounts: positive = credit (money in),
      # negative = debit (money out). Sure expects the opposite (positive =
      # money out), so negate.
      -amount
    end

    def merchant_for(data)
      merchant_name = data[:merchantName].to_s.strip
      return nil if merchant_name.blank?

      merchant_id = Digest::SHA256.hexdigest(merchant_name.downcase)[0, 32]

      import_adapter.find_or_create_merchant(
        provider_merchant_id: "redbark_merchant_#{merchant_id}",
        name: merchant_name,
        source: "redbark"
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "RedbarkAccount::Transactions::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
      nil
    end

    def build_extra_metadata(data)
      {
        "redbark" => {
          "id" => data[:id],
          "pending" => data[:status].to_s == "pending",
          "merchant" => data[:merchantName],
          "category" => data[:category],
          "merchant_category_code" => data[:merchantCategoryCode],
          "direction" => data[:direction]
        }.compact
      }
    end
end
