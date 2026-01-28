# Provides currency normalization and validation for provider data imports
#
# This concern provides a shared method to parse and normalize currency codes
# from external providers (Plaid, SimpleFIN, LunchFlow, Enable Banking), ensuring:
# - Consistent uppercase formatting (e.g., "eur" -> "EUR")
# - Validation against Money gem's known currencies (not just 3-letter format)
# - Proper handling of nil, empty, and invalid values (e.g., "XXX")
#
# Usage:
#   include CurrencyNormalizable
#   currency = parse_currency(api_data[:currency])
module CurrencyNormalizable
  extend ActiveSupport::Concern

  private

    # Parse and normalize a currency code from provider data
    #
    # @param currency_value [String, nil] Raw currency value from provider API
    # @return [String, nil] Normalized uppercase 3-letter currency code, or nil if invalid
    #
    # @example
    #   parse_currency("usd")     # => "USD"
    #   parse_currency("EUR")     # => "EUR"
    #   parse_currency("  gbp  ") # => "GBP"
    #   parse_currency("XXX")     # => nil (not a valid Money currency)
    #   parse_currency("invalid") # => nil (logs warning)
    #   parse_currency(nil)       # => nil
    #   parse_currency("")        # => nil
    def parse_currency(currency_value)
      # Handle nil, empty string, or whitespace-only strings
      return nil if currency_value.blank?

      # Normalize to uppercase 3-letter code
      normalized = currency_value.to_s.strip.upcase

      # Validate it's a 3-letter format first
      unless normalized.match?(/\A[A-Z]{3}\z/)
        log_invalid_currency(currency_value)
        return nil
      end

      # Validate against Money gem's known currencies
      # This catches codes like "XXX" which are 3 letters but not valid for monetary operations
      if valid_money_currency?(normalized)
        normalized
      else
        log_invalid_currency(currency_value)
        nil
      end
    end

    # Check if a currency code is valid in the Money gem
    #
    # @param code [String] Uppercase 3-letter currency code
    # @return [Boolean] true if the Money gem recognizes this currency
    def valid_money_currency?(code)
      Money::Currency.new(code)
      true
    rescue Money::Currency::UnknownCurrencyError
      false
    end

    # Log warning for invalid currency codes
    # Override this method in including classes to provide context-specific logging
    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}', defaulting to fallback")
    end
end
