module SnaptradeAccount::DataHelpers
  extend ActiveSupport::Concern

  private

    # Convert SnapTrade SDK objects to hashes
    # SDK objects don't have proper to_h but do have to_json
    # Uses JSON round-trip to ensure all nested objects become hashes
    def sdk_object_to_hash(obj)
      return obj if obj.is_a?(Hash)

      if obj.respond_to?(:to_json)
        JSON.parse(obj.to_json)
      elsif obj.respond_to?(:to_h)
        obj.to_h
      else
        obj
      end
    rescue JSON::ParserError, TypeError
      obj.respond_to?(:to_h) ? obj.to_h : {}
    end

    def parse_decimal(value)
      return nil if value.nil?

      case value
      when BigDecimal
        value
      when String
        BigDecimal(value)
      when Numeric
        BigDecimal(value.to_s)
      else
        nil
      end
    rescue ArgumentError => e
      Rails.logger.error("Failed to parse decimal value: #{value.inspect} - #{e.message}")
      nil
    end

    def parse_date(date_value)
      return nil if date_value.nil?

      case date_value
      when Date
        date_value
      when String
        Date.parse(date_value)
      when Time, DateTime, ActiveSupport::TimeWithZone
        date_value.to_date
      else
        nil
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse date: #{date_value.inspect} - #{e.message}")
      nil
    end

    def resolve_security(symbol, symbol_data)
      ticker = symbol.to_s.upcase.strip
      return nil if ticker.blank?

      security = Security.find_by(ticker: ticker)

      # If security exists but has a bad name (looks like a hash), update it
      if security && security.name&.start_with?("{")
        new_name = extract_security_name(symbol_data, ticker)
        Rails.logger.info "SnaptradeAccount - Fixing security name: #{security.name.first(50)}... -> #{new_name}"
        security.update!(name: new_name)
      end

      return security if security

      # Create new security
      security_name = extract_security_name(symbol_data, ticker)

      Rails.logger.info "SnaptradeAccount - Creating security: ticker=#{ticker}, name=#{security_name}"

      Security.create!(
        ticker: ticker,
        name: security_name,
        exchange_mic: extract_exchange(symbol_data),
        country_code: extract_country_code(symbol_data)
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      # Handle race condition - another process may have created it
      Rails.logger.error "Failed to create security #{ticker}: #{e.message}"
      Security.find_by(ticker: ticker) # Retry find in case of race condition
    end

    def extract_security_name(symbol_data, fallback_ticker)
      # Try various paths where the name might be
      name = symbol_data[:description] || symbol_data["description"]

      # If description is missing or looks like a type description, use ticker
      if name.blank? || name.is_a?(Hash) || name =~ /^(COMMON STOCK|CRYPTOCURRENCY|ETF|MUTUAL FUND)$/i
        name = fallback_ticker
      end

      # Titleize for readability if it's all caps
      name = name.titleize if name == name.upcase && name.length > 4

      name
    end

    def extract_exchange(symbol_data)
      exchange = symbol_data[:exchange] || symbol_data["exchange"]
      return nil unless exchange.is_a?(Hash)

      exchange.with_indifferent_access[:mic_code] || exchange.with_indifferent_access[:id]
    end

    def extract_country_code(symbol_data)
      # Try to extract country from currency or exchange
      currency = symbol_data[:currency]
      currency = currency.dig(:code) if currency.is_a?(Hash)

      case currency
      when "USD"
        "US"
      when "CAD"
        "CA"
      when "GBP", "GBX"
        "GB"
      when "EUR"
        nil # Could be many countries
      else
        nil
      end
    end

    def extract_currency(data, symbol_data = {}, fallback_currency = nil)
      currency_data = data[:currency] || data["currency"] || symbol_data[:currency] || symbol_data["currency"]

      if currency_data.is_a?(Hash)
        currency_data.with_indifferent_access[:code]
      elsif currency_data.is_a?(String)
        currency_data
      else
        fallback_currency
      end
    end
end
