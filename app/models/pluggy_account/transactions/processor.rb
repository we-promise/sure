# frozen_string_literal: true

class PluggyAccount::Transactions::Processor
  include PluggyAccount::DataHelpers
  include PluggyTransactionHash

  attr_reader :pluggy_account

  def initialize(pluggy_account)
    @pluggy_account = pluggy_account
  end

  def process
    unless pluggy_account.raw_transactions_payload.present?
      Rails.logger.info "PluggyAccount::Transactions::Processor - No transactions in raw_transactions_payload for pluggy_account #{pluggy_account.id}"
      return { success: true, total: 0, imported: 0, failed: 0, errors: [] }
    end

    total_count = pluggy_account.raw_transactions_payload.count
    Rails.logger.info "PluggyAccount::Transactions::Processor - Processing #{total_count} transactions for pluggy_account #{pluggy_account.id}"

    imported_count = 0
    failed_count = 0
    errors = []

    # Each entry is processed inside a transaction, but to avoid locking up the DB when
    # there are hundreds or thousands of transactions, we process them individually.
    pluggy_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      begin
        result = process_transaction(transaction_data)

        if result.nil?
          # Transaction was skipped (e.g., no linked account or blank external_id)
          failed_count += 1
          transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
          errors << { index: index, transaction_id: transaction_id, error: "Skipped" }
        else
          imported_count += 1
        end
      rescue ArgumentError => e
        # Validation error - log and continue
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "Validation error: #{e.message}"
        Rails.logger.error "PluggyAccount::Transactions::Processor - #{error_message} (transaction #{transaction_id})"
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      rescue => e
        # Unexpected error - log with full context and continue
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "#{e.class}: #{e.message}"
        Rails.logger.error "PluggyAccount::Transactions::Processor - Error processing transaction #{transaction_id}: #{error_message}"
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
      Rails.logger.warn "PluggyAccount::Transactions::Processor - Completed with #{failed_count} failures out of #{total_count} transactions"
    else
      Rails.logger.info "PluggyAccount::Transactions::Processor - Successfully processed #{imported_count} transactions"
    end

    result
  end

  private

    def account
      @pluggy_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_transaction(transaction_data)
      return nil unless account.present?

      data = transaction_data.with_indifferent_access

      # TODO: Customize based on your provider's transaction format
      # Extract transaction fields from the provider's API response
      external_id = (data[:id] || data[:transaction_id]).to_s
      return nil if external_id.blank?

      # Parse transaction attributes
      amount = parse_transaction_amount(data)
      return nil if amount.nil?

      # TODO: Customize date field names based on your provider
      date = parse_date(data[:date] || data[:transaction_date] || data[:posted_at])
      return nil if date.nil?

      name = data[:name] || data[:description] || data[:merchant_name] || "Transaction"
      currency = extract_currency(data, fallback: account.currency)

      # Build provider-specific metadata for transaction.extra
      extra = build_extra_metadata(data)

      Rails.logger.info "PluggyAccount::Transactions::Processor - Importing transaction: id=#{external_id} amount=#{amount} date=#{date}"

      # Use ProviderImportAdapter for proper deduplication via external_id + source
      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: name[0..254], # Limit to 255 chars
        source: "pluggy",
        extra: extra
      )
    end

    def parse_transaction_amount(data)
      data = data.with_indifferent_access
      amount = parse_decimal(data[:amount])
      return nil if amount.nil?

      # Pluggy convention: positive = credit (money in), negative = debit (money out).
      # Sure convention: positive = money out, negative = money in.
      # Negate so Pluggy credits become Sure inflows (negative) and vice versa.
      -amount
    end

    def build_extra_metadata(data)
      data = data.with_indifferent_access
      merchant = data[:merchant]
      merchant = merchant[:name] if merchant.is_a?(Hash)

      {
        "pluggy" => {
          "id" => data[:id]&.to_s,
          "pending" => (data[:status].to_s.upcase == "PENDING"),
          "merchant" => merchant,
          "category" => data[:category]
        }.compact
      }
    end

    # Override DataHelpers#extract_currency to honor Pluggy's `currencyCode`
    # (Pluggy returns `currencyCode`, not `currency`).
    def extract_currency(data, fallback: nil)
      data = data.with_indifferent_access
      code = data[:currencyCode] || data[:currency]
      code = code[:code] if code.is_a?(Hash)
      return fallback if code.blank?
      code.to_s.upcase
    end
end
