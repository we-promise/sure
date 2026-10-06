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

    # A ticker can have several Security rows (one per exchange), so the
    # lookup must be deterministic or a holding flips between rows from one
    # sync to the next (#333). Order: the row the account already holds, the
    # row on SnapTrade's reported exchange, then a fixed preference order.
    def resolve_security(symbol, symbol_data, account: nil)
      ticker = symbol.to_s.upcase.strip
      return nil if ticker.blank?

      security = existing_security_for(ticker, symbol_data, account)

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
      existing_security_for(ticker, symbol_data, account) # Retry find in case of race condition
    end

    def existing_security_for(ticker, symbol_data, account)
      held_security_for(account, ticker) ||
        reported_exchange_security_for(ticker, symbol_data) ||
        preferred_security_for(ticker)
    end

    # The row the position currently sits on, so it never moves. That includes
    # a same-ticker remap: SnapTrade sends no external_id, so the import
    # adapter's provider_security fallbacks never run for it. Latest date
    # wins, provider holdings first.
    def held_security_for(account, ticker)
      return nil unless account

      security_id = account.holdings
        .joins(:security)
        .where("UPPER(securities.ticker) = ?", ticker)
        .order(date: :desc)
        .order(Arel.sql("holdings.account_provider_id IS NULL"), :id)
        .pick(:security_id)

      security_id && Security.find_by(id: security_id)
    end

    def reported_exchange_security_for(ticker, symbol_data)
      exchange = extract_exchange(symbol_data)
      return nil if exchange.blank?

      # Rows SnapTrade created carry its exchange in exchange_mic, not
      # exchange_operating_mic, so they need a second match.
      Security.find_by_ticker_and_exchange(ticker: ticker, exchange_operating_mic: exchange) ||
        Security.where("UPPER(ticker) = ?", ticker).where(exchange_mic: exchange).order(:created_at, :id).first
    end

    def preferred_security_for(ticker)
      Security.where("UPPER(ticker) = ?", ticker)
        .order(:offline, Arel.sql("price_provider IS NULL"), :created_at, :id)
        .first
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
      return exchange.presence if exchange.is_a?(String)
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

    # Security metadata sits under `instrument`, or under `symbol.symbol` in
    # payloads persisted to raw_holdings_payload before the /positions/all
    # migration, which are re-read until the next sync overwrites them.
    def extract_symbol_data(data)
      instrument = data[:instrument] || data["instrument"]
      return instrument.with_indifferent_access if instrument.is_a?(Hash)

      symbol_wrapper = data[:symbol].is_a?(Hash) ? data[:symbol].with_indifferent_access : {}
      raw_symbol_data = symbol_wrapper[:symbol]

      raw_symbol_data.is_a?(Hash) ? raw_symbol_data.with_indifferent_access : {}
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
