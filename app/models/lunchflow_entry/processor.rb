require "digest/md5"

class LunchflowEntry::Processor
  include CurrencyNormalizable
  # lunchflow_transaction is the raw hash fetched from Lunchflow API and converted to JSONB
  # Transaction structure: { id, accountId, amount, currency, date, merchant, description }
  def initialize(lunchflow_transaction, lunchflow_account:)
    @lunchflow_transaction = lunchflow_transaction
    @lunchflow_account = lunchflow_account
  end

  def process
    # Validate that we have a linked account before processing
    unless account.present?
      Rails.logger.warn "LunchflowEntry::Processor - No linked account for lunchflow_account #{lunchflow_account.id}, skipping transaction #{external_id}"
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
        source: "lunchflow",
        merchant: merchant
      )
    rescue ArgumentError => e
      # Re-raise validation errors (missing required fields, invalid data)
      Rails.logger.error "LunchflowEntry::Processor - Validation error for transaction #{external_id}: #{e.message}"
      raise
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      # Handle database save errors
      Rails.logger.error "LunchflowEntry::Processor - Failed to save transaction #{external_id}: #{e.message}"
      raise StandardError.new("Failed to import transaction: #{e.message}")
    rescue => e
      # Catch unexpected errors with full context
      Rails.logger.error "LunchflowEntry::Processor - Unexpected error processing transaction #{external_id}: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise StandardError.new("Unexpected error importing transaction: #{e.message}")
    end
  end

  private
    attr_reader :lunchflow_transaction, :lunchflow_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= lunchflow_account.current_account
    end

    def data
      @data ||= lunchflow_transaction.with_indifferent_access
    end

    def external_id
      id = data[:id].presence
      raise ArgumentError, "Lunchflow transaction missing required field 'id'" unless id
      "lunchflow_#{id}"
    end

    def name
      # Use Lunchflow's merchant and description to create informative transaction names
      merchant_name = data[:merchant]
      description = data[:description]

      # Combine merchant + description when both are present and different
      if merchant_name.present? && description.present? && merchant_name != description
        "#{merchant_name} - #{description}"
      elsif merchant_name.present?
        merchant_name
      elsif description.present?
        description
      else
        "Unknown transaction"
      end
    end

    def merchant
      return nil unless data[:merchant].present?

      # Create a stable merchant ID from the merchant name
      # Using digest to ensure uniqueness while keeping it deterministic
      merchant_name = data[:merchant].to_s.strip
      return nil if merchant_name.blank?

      merchant_id = Digest::MD5.hexdigest(merchant_name.downcase)

      @merchant ||= begin
        import_adapter.find_or_create_merchant(
          provider_merchant_id: "lunchflow_merchant_#{merchant_id}",
          name: merchant_name,
          source: "lunchflow"
        )
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "LunchflowEntry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
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

      # Lunchflow likely uses standard convention where negative is expense, positive is income
      # Maybe expects opposite convention (expenses positive, income negative)
      # So we negate the amount to convert from Lunchflow to Maybe format
      -parsed_amount
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse Lunchflow transaction amount: #{data[:amount].inspect} - #{e.message}"
      raise
    end

    def currency
      parse_currency(data[:currency]) || account&.currency || "USD"
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in LunchFlow transaction #{external_id}, falling back to account currency")
    end

    def date
      case data[:date]
      when String
        Date.parse(data[:date])
      when Integer, Float
        # Unix timestamp
        Time.at(data[:date]).to_date
      when Time, DateTime
        data[:date].to_date
      when Date
        data[:date]
      else
        Rails.logger.error("Lunchflow transaction has invalid date value: #{data[:date].inspect}")
        raise ArgumentError, "Invalid date format: #{data[:date].inspect}"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse Lunchflow transaction date '#{data[:date]}': #{e.message}")
      raise ArgumentError, "Unable to parse transaction date: #{data[:date].inspect}"
    end
end
