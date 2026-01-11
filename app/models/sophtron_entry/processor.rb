require "digest/md5"

# Processes a single Sophtron transaction and creates/updates a Maybe Transaction.
#
# This processor takes raw transaction data from the Sophtron API and converts it
# into a Maybe Transaction record using the Account::ProviderImportAdapter.
# It handles currency normalization, merchant matching, and data validation.
#
# Expected transaction structure from Sophtron:
# {
#   id: String,
#   accountId: String,
#   amount: Numeric,
#   currency: String,
#   date: String/Date,
#   merchant: String,
#   description: String
# }
class SophtronEntry::Processor
  include CurrencyNormalizable

  # Initializes a new processor for a Sophtron transaction.
  #
  # @param sophtron_transaction [Hash] Raw transaction data from Sophtron API
  # @param sophtron_account [SophtronAccount] The account this transaction belongs to
  def initialize(sophtron_transaction, sophtron_account:)
    @sophtron_transaction = sophtron_transaction
    @sophtron_account = sophtron_account
  end

  # Processes the transaction and creates/updates a Maybe Transaction record.
  #
  # This method validates the transaction data, creates or finds a merchant,
  # and uses the ProviderImportAdapter to import the transaction into Maybe.
  # It respects user overrides through the enrichment pattern.
  #
  # @return [Entry, nil] The created/updated Entry, or nil if account not linked
  # @raise [ArgumentError] if required transaction fields are missing
  # @raise [StandardError] if the transaction cannot be saved
  def process
    # Validate that we have a linked account before processing
    unless account.present?
      Rails.logger.warn "SophtronEntry::Processor - No linked account for sophtron_account #{sophtron_account.id}, skipping transaction #{external_id}"
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
        source: "sophtron",
        merchant: merchant,
        notes: notes
      )
    rescue ArgumentError => e
      # Re-raise validation errors (missing required fields, invalid data)
      Rails.logger.error "SophtronEntry::Processor - Validation error for transaction #{external_id}: #{e.message}"
      raise
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      # Handle database save errors
      Rails.logger.error "SophtronEntry::Processor - Failed to save transaction #{external_id}: #{e.message}"
      raise StandardError.new("Failed to import transaction: #{e.message}")
    rescue => e
      # Catch unexpected errors with full context
      Rails.logger.error "SophtronEntry::Processor - Unexpected error processing transaction #{external_id}: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise StandardError.new("Unexpected error importing transaction: #{e.message}")
    end
  end

  private
    attr_reader :sophtron_transaction, :sophtron_account

    # Returns the import adapter for this transaction's account.
    #
    # @return [Account::ProviderImportAdapter] Adapter for importing transactions
    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    # Returns the linked Maybe Account for this transaction.
    #
    # @return [Account, nil] The linked account
    def account
      @account ||= sophtron_account.current_account
    end

    # Returns the transaction data with indifferent access.
    #
    # @return [ActiveSupport::HashWithIndifferentAccess] Normalized transaction data
    def data
      @data ||= sophtron_transaction.with_indifferent_access
    end

    # Generates a unique external ID for this transaction.
    #
    # Prefixes the Sophtron transaction ID with 'sophtron_' to avoid conflicts
    # with other providers.
    #
    # @return [String] The external ID (e.g., 'sophtron_12345')
    # @raise [ArgumentError] if the transaction ID is missing
    def external_id
      id = data[:id].presence
      raise ArgumentError, "Sophtron transaction missing required field 'id'" unless id
      "sophtron_#{id}"
    end

    # Extracts the transaction name from the data.
    #
    # Falls back to "Unknown transaction" if merchant is not present.
    #
    # @return [String] The transaction name
    def name
      data[:merchant].presence || t("sophtron_items.sophtron_entry.processor.unknown_transaction")
    end

    # Extracts optional notes/description from the transaction.
    #
    # @return [String, nil] Transaction description
    def notes
      data[:description].presence
    end

    # Finds or creates a merchant for this transaction.
    #
    # Creates a deterministic merchant ID using MD5 hash of the merchant name.
    # This ensures the same merchant name always maps to the same merchant record.
    #
    # @return [Merchant, nil] The merchant object, or nil if merchant data is missing
    def merchant
      return nil unless data[:merchant].present?

      # Create a stable merchant ID from the merchant name
      # Using digest to ensure uniqueness while keeping it deterministic
      merchant_name = data[:merchant].to_s.strip
      return nil if merchant_name.blank?

      merchant_id = Digest::MD5.hexdigest(merchant_name.downcase)

      @merchant ||= begin
        import_adapter.find_or_create_merchant(
          provider_merchant_id: "sophtron_merchant_#{merchant_id}",
          name: merchant_name,
          source: "sophtron"
        )
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "SophtronEntry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
        nil
      end
    end

    # Parses and converts the transaction amount.
    #
    # Sophtron uses standard banking convention (negative = expense, positive = income)
    # while Maybe uses inverted signs (positive = expense, negative = income).
    # This method negates the amount to convert between conventions.
    #
    # @return [BigDecimal] The converted amount
    # @raise [ArgumentError] if the amount cannot be parsed
    def amount
      parsed_amount = case data[:amount]
      when String
        BigDecimal(data[:amount])
      when Numeric
        BigDecimal(data[:amount].to_s)
      else
        BigDecimal("0")
      end

      # Sophtron likely uses standard convention where negative is expense, positive is income
      # Maybe expects opposite convention (expenses positive, income negative)
      # So we negate the amount to convert from Sophtron to Maybe format
      -parsed_amount
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse Sophtron transaction amount: #{data[:amount].inspect} - #{e.message}"
      raise
    end

    # Extracts and normalizes the currency code.
    #
    # Falls back to the account currency, then USD if not specified.
    #
    # @return [String] Three-letter currency code (e.g., 'USD')
    def currency
      parse_currency(data[:currency]) || account&.currency || "USD"
    end

    # Logs invalid currency codes.
    #
    # @param currency_value [String] The invalid currency code
    # @return [void]
    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in Sophtron transaction #{external_id}, falling back to account currency")
    end

    # Parses the transaction date from various formats.
    #
    # Handles:
    # - String dates (ISO format)
    # - Unix timestamps (Integer/Float)
    # - Time/DateTime objects
    # - Date objects
    #
    # @return [Date] The parsed transaction date
    # @raise [ArgumentError] if the date cannot be parsed
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
        Rails.logger.error("Sophtron transaction has invalid date value: #{data[:date].inspect}")
        raise ArgumentError, "Invalid date format: #{data[:date].inspect}"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse Sophtron transaction date '#{data[:date]}': #{e.message}")
      raise ArgumentError, "Unable to parse transaction date: #{data[:date].inspect}"
    end
end
