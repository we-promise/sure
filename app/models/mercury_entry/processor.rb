require "digest/md5"

class MercuryEntry::Processor
  include CurrencyNormalizable

  # mercury_transaction is the raw hash fetched from Mercury API and converted to JSONB
  # Transaction structure: { id, amount, bankDescription, counterpartyId, counterpartyName,
  #                          counterpartyNickname, createdAt, dashboardLink, details,
  #                          estimatedDeliveryDate, failedAt, kind, note, postedAt,
  #                          reasonForFailure, status }
  def initialize(mercury_transaction, mercury_account:)
    @mercury_transaction = mercury_transaction
    @mercury_account = mercury_account
  end

  def process
    # Validate that we have a linked account before processing
    unless account.present?
      Rails.logger.warn "MercuryEntry::Processor - No linked account for mercury_account #{mercury_account.id}, skipping transaction #{external_id}"
      return nil
    end

    # Skip failed transactions
    if data[:status] == "failed"
      Rails.logger.debug "MercuryEntry::Processor - Skipping failed transaction #{external_id}"
      return nil
    end

    # Wrap import in error handling to catch validation and save errors
    begin
      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: name,
        source: "mercury",
        merchant: merchant,
        notes: notes
      )
    rescue ArgumentError => e
      # Re-raise validation errors (missing required fields, invalid data)
      Rails.logger.error "MercuryEntry::Processor - Validation error for transaction #{external_id}: #{e.message}"
      raise
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      # Handle database save errors
      Rails.logger.error "MercuryEntry::Processor - Failed to save transaction #{external_id}: #{e.message}"
      raise StandardError.new("Failed to import transaction: #{e.message}")
    rescue => e
      # Catch unexpected errors with full context
      Rails.logger.error "MercuryEntry::Processor - Unexpected error processing transaction #{external_id}: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise StandardError.new("Unexpected error importing transaction: #{e.message}")
    end
  end

  private
    attr_reader :mercury_transaction, :mercury_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= mercury_account.current_account
    end

    def data
      @data ||= mercury_transaction.with_indifferent_access
    end

    def external_id
      id = data[:id].presence
      raise ArgumentError, "Mercury transaction missing required field 'id'" unless id
      "mercury_#{id}"
    end

    def name
      # Use counterparty name or bank description
      data[:counterpartyNickname].presence ||
        data[:counterpartyName].presence ||
        data[:bankDescription].presence ||
        "Unknown transaction"
    end

    def notes
      # Combine note and details if present
      note_parts = []
      note_parts << data[:note] if data[:note].present?
      note_parts << data[:details] if data[:details].present?
      note_parts.any? ? note_parts.join(" - ") : nil
    end

    def merchant
      counterparty_name = data[:counterpartyName].presence
      return nil unless counterparty_name.present?

      # Create a stable merchant ID from the counterparty name
      # Using digest to ensure uniqueness while keeping it deterministic
      merchant_name = counterparty_name.to_s.strip
      return nil if merchant_name.blank?

      merchant_id = Digest::MD5.hexdigest(merchant_name.downcase)

      @merchant ||= begin
        import_adapter.find_or_create_merchant(
          provider_merchant_id: "mercury_merchant_#{merchant_id}",
          name: merchant_name,
          source: "mercury"
        )
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "MercuryEntry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
        nil
      end
    end

    def amount
      parsed_amount = case data[:amount]
      when String
        BigDecimal(data[:amount])
      when Numeric
        BigDecimal(data[:amount].to_s)
      else
        BigDecimal("0")
      end

      # Mercury uses standard convention where:
      # - Negative amounts are money going out (expenses)
      # - Positive amounts are money coming in (income)
      # Our app uses opposite convention (expenses positive, income negative)
      # So we negate the amount to convert from Mercury to our format
      -parsed_amount
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse Mercury transaction amount: #{data[:amount].inspect} - #{e.message}"
      raise
    end

    def currency
      # Mercury is US-only, always USD
      "USD"
    end

    def date
      # Mercury provides createdAt and postedAt - use postedAt if available, otherwise createdAt
      date_value = data[:postedAt].presence || data[:createdAt].presence

      case date_value
      when String
        # Mercury uses ISO 8601 format: "2024-01-15T10:30:00Z"
        DateTime.parse(date_value).to_date
      when Integer, Float
        # Unix timestamp
        Time.at(date_value).to_date
      when Time, DateTime
        date_value.to_date
      when Date
        date_value
      else
        Rails.logger.error("Mercury transaction has invalid date value: #{date_value.inspect}")
        raise ArgumentError, "Invalid date format: #{date_value.inspect}"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse Mercury transaction date '#{date_value}': #{e.message}")
      raise ArgumentError, "Unable to parse transaction date: #{date_value.inspect}"
    end
end
