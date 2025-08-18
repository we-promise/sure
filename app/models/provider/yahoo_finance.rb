class Provider::YahooFinance < Provider
  include ExchangeRateConcept, SecurityConcept

  # Subclass so errors caught in this provider are raised as Provider::YahooFinance::Error
  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)
  InvalidSymbolError = Class.new(Error)
  MarketClosedError = Class.new(Error)

  # Cache duration for repeated requests (5 minutes)
  CACHE_DURATION = 5.minutes

  def initialize
    # Yahoo Finance doesn't require an API key but we may want to add proxy support later
    @cache = {}
  end

  def healthy?
    Rails.logger.info "[YahooFinance] Performing health check"
    with_provider_response do
      # Test with a known stable ticker (Apple)
      response = client.get("#{base_url}/v8/finance/chart/AAPL") do |req|
        req.params["interval"] = "1d"
        req.params["range"] = "1d"
      end

      data = JSON.parse(response.body)
      result = data.dig("chart", "result")
      health_status = result.present? && result.any?

      Rails.logger.info "[YahooFinance] Health check #{health_status ? 'passed' : 'failed'}"
      health_status
    end
  end

  def usage
    Rails.logger.info "[YahooFinance] Fetching usage data (mock)"
    # Yahoo Finance doesn't expose usage data, so we return a mock structure
    with_provider_response do
      usage_data = UsageData.new(
        used: 0,
        limit: 2000, # Estimated daily limit based on community knowledge
        utilization: 0,
        plan: "Free"
      )

      Rails.logger.info "[YahooFinance] Usage data: #{usage_data.plan} plan, #{usage_data.used}/#{usage_data.limit} requests"
      usage_data
    end
  end

  # ================================
  #          Exchange Rates
  # ================================

  def fetch_exchange_rate(from:, to:, date:)
    validate_currency_codes!(from, to)
    Rails.logger.info "[YahooFinance] Fetching exchange rate #{from}/#{to} for #{date}"

    with_provider_response do
      # Return 1.0 if same currency
      return Rate.new(date: date, from: from, to: to, rate: 1.0) if from == to

      cache_key = "exchange_rate_#{from}_#{to}_#{date}"
      if cached_result = get_cached_result(cache_key)
        return cached_result
      end

      # For a single date, we'll fetch a range and find the closest match
      end_date = date
      start_date = date - 10.days # Extended range for better coverage

      rates = fetch_exchange_rates(
        from: from,
        to: to,
        start_date: start_date,
        end_date: end_date
      )

      return rates.first if rates.length == 1

      # Find the exact date or the closest previous date
      target_rate = rates.find { |r| r.date == date } ||
                   rates.select { |r| r.date <= date }.max_by(&:date)

      raise Error, "No exchange rate found for #{from}/#{to} on or before #{date}" unless target_rate

      cache_result(cache_key, target_rate)
      Rails.logger.info "[YahooFinance] Successfully fetched exchange rate #{from}/#{to}: #{target_rate.rate} on #{target_rate.date}"
      target_rate
    end
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    validate_currency_codes!(from, to)
    validate_date_range!(start_date, end_date)

    Rails.logger.info "[YahooFinance] Fetching exchange rates #{from}/#{to} from #{start_date} to #{end_date}"
    with_provider_response do
      # Return 1.0 rates if same currency
      if from == to
        return generate_same_currency_rates(from, to, start_date, end_date)
      end

      cache_key = "exchange_rates_#{from}_#{to}_#{start_date}_#{end_date}"
      if cached_result = get_cached_result(cache_key)
        return cached_result
      end

      # Try both direct and inverse currency pairs
      rates = fetch_currency_pair_data(from, to, start_date, end_date) ||
              fetch_inverse_currency_pair_data(from, to, start_date, end_date)

      raise Error, "No chart data found for currency pair #{from}/#{to}" unless rates&.any?

      cache_result(cache_key, rates)
      Rails.logger.info "[YahooFinance] Successfully fetched #{rates.length} exchange rates for #{from}/#{to}"
      rates
    rescue JSON::ParserError => e
      Rails.logger.error "[YahooFinance] JSON parsing error for #{from}/#{to}: #{e.message}"
      raise Error, "Invalid response format: #{e.message}"
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    validate_symbol!(symbol)
    Rails.logger.info "[YahooFinance] Searching securities for symbol: #{symbol}"

    with_provider_response do
      cache_key = "search_#{symbol}_#{country_code}_#{exchange_operating_mic}"
      if cached_result = get_cached_result(cache_key)
        return cached_result
      end

      response = client.get("#{base_url}/v1/finance/search") do |req|
        req.params["q"] = symbol.strip.upcase
        req.params["quotesCount"] = 25
      end

      data = JSON.parse(response.body)
      quotes = data.dig("quotes") || []

      securities = quotes.filter_map do |quote|
        # Support more security types
        supported_types = %w[Equity ETF Index Cryptocurrency Currency]
        next unless supported_types.include?(quote["typeDisp"])

        # Apply filters if provided
        if country_code.present?
          country = map_country_code(quote["exchDisp"])
          next unless country == country_code
        end

        if exchange_operating_mic.present?
          mic = map_exchange_mic(quote["exchange"])
          next unless mic == exchange_operating_mic
        end

        Security.new(
          symbol: quote["symbol"],
          name: quote["longname"] || quote["shortname"] || quote["symbol"],
          logo_url: nil, # Yahoo search doesn't provide logos
          exchange_operating_mic: map_exchange_mic(quote["exchange"]),
          country_code: map_country_code(quote["exchDisp"])
        )
      end

      cache_result(cache_key, securities)
      Rails.logger.info "[YahooFinance] Found #{securities.length} securities for symbol: #{symbol}"
      securities
    rescue JSON::ParserError => e
      Rails.logger.error "[YahooFinance] JSON parsing error for search #{symbol}: #{e.message}"
      raise Error, "Invalid search response format: #{e.message}"
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    Rails.logger.info "[YahooFinance] Fetching security info for #{symbol} (MIC: #{exchange_operating_mic})"
    with_provider_response do
      # Use quoteSummary endpoint which is more reliable
      response = client.get("#{base_url}/v10/finance/quoteSummary/#{symbol}") do |req|
        req.params["modules"] = "assetProfile,price,quoteType"
      end

      data = JSON.parse(response.body)
      result = data.dig("quoteSummary", "result", 0)

      raise Error, "No security info found for #{symbol}" unless result

      asset_profile = result["assetProfile"] || {}
      price_info = result["price"] || {}
      quote_type = result["quoteType"] || {}

      security_info = SecurityInfo.new(
        symbol: symbol,
        name: price_info["longName"] || price_info["shortName"] || quote_type["longName"] || quote_type["shortName"],
        links: asset_profile["website"],
        logo_url: nil, # Yahoo doesn't provide reliable logo URLs
        description: asset_profile["longBusinessSummary"],
        kind: map_security_type(quote_type["quoteType"]),
        exchange_operating_mic: exchange_operating_mic
      )

      Rails.logger.info "[YahooFinance] Successfully fetched security info for #{symbol}: #{security_info.name}"
      security_info
    rescue JSON::ParserError => e
      Rails.logger.error "[YahooFinance] JSON parsing error for security info #{symbol}: #{e.message}"
      raise Error, "Invalid response format: #{e.message}"
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    validate_symbol!(symbol)
    Rails.logger.info "[YahooFinance] Fetching security price for #{symbol} on #{date}"

    with_provider_response do
      cache_key = "security_price_#{symbol}_#{exchange_operating_mic}_#{date}"
      if cached_result = get_cached_result(cache_key)
        return cached_result
      end

      # For a single date, we'll fetch a range and find the closest match
      end_date = date
      start_date = date - 10.days # Extended range for better coverage

      prices = fetch_security_prices(
        symbol: symbol,
        exchange_operating_mic: exchange_operating_mic,
        start_date: start_date,
        end_date: end_date
      )

      return prices.first if prices.length == 1

      # Find the exact date or the closest previous date
      target_price = prices.find { |p| p.date == date } ||
                    prices.select { |p| p.date <= date }.max_by(&:date)

      raise Error, "No price found for #{symbol} on or before #{date}" unless target_price

      cache_result(cache_key, target_price)
      Rails.logger.info "[YahooFinance] Successfully fetched security price for #{symbol}: #{target_price.price} on #{target_price.date}"
      target_price
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    Rails.logger.info "[YahooFinance] Fetching security prices for #{symbol} from #{start_date} to #{end_date}"
    with_provider_response do
      # Convert dates to Unix timestamps
      period1 = start_date.to_time.to_i
      period2 = end_date.end_of_day.to_time.to_i

      Rails.logger.debug "[YahooFinance] Requesting chart data for security: #{symbol}"
      response = client.get("#{base_url}/v8/finance/chart/#{symbol}") do |req|
        req.params["period1"] = period1
        req.params["period2"] = period2
        req.params["interval"] = "1d"
        req.params["includeAdjustedClose"] = true
      end

      data = JSON.parse(response.body)
      chart_data = data.dig("chart", "result", 0)

      raise Error, "No chart data found for #{symbol}" unless chart_data

      timestamps = chart_data.dig("timestamp") || []
      quotes = chart_data.dig("indicators", "quote", 0) || {}
      closes = quotes["close"] || []

      # Get currency from metadata
      currency = chart_data.dig("meta", "currency") || "USD"

      prices = []
      timestamps.each_with_index do |timestamp, index|
        close_price = closes[index]
        next if close_price.nil? # Skip days with no data (weekends, holidays)

        prices << Price.new(
          symbol: symbol,
          date: Time.at(timestamp).to_date,
          price: close_price.to_f,
          currency: currency,
          exchange_operating_mic: exchange_operating_mic
        )
      end

      sorted_prices = prices.sort_by(&:date)
      Rails.logger.info "[YahooFinance] Successfully fetched #{sorted_prices.length} security prices for #{symbol} in #{currency}"
      sorted_prices
    rescue JSON::ParserError => e
      Rails.logger.error "[YahooFinance] JSON parsing error for security prices #{symbol}: #{e.message}"
      raise Error, "Invalid response format: #{e.message}"
    end
  end

  private

    def base_url
      ENV["YAHOO_FINANCE_URL"] || "https://query1.finance.yahoo.com"
    end

    # ================================
    #           Validation
    # ================================

    def validate_currency_codes!(from, to)
      valid_currencies = %w[USD EUR GBP JPY CHF CAD AUD NZD SEK NOK DKK PLN CZK HUF RUB CNY INR KRW SGD HKD MXN BRL ZAR]

      raise InvalidSymbolError, "Invalid 'from' currency: #{from}" unless from.present? && valid_currencies.include?(from.upcase)
      raise InvalidSymbolError, "Invalid 'to' currency: #{to}" unless to.present? && valid_currencies.include?(to.upcase)
    end

    def validate_symbol!(symbol)
      raise InvalidSymbolError, "Symbol cannot be blank" if symbol.blank?
      raise InvalidSymbolError, "Symbol too long (max 10 characters)" if symbol.length > 10
      raise InvalidSymbolError, "Invalid symbol format" unless symbol.match?(/\A[A-Z0-9\.\-_]+\z/i)
    end

    def validate_date_range!(start_date, end_date)
      raise Error, "Start date cannot be after end date" if start_date > end_date
      raise Error, "Date range too large (max 5 years)" if (end_date - start_date) > 5.years
    end

    # ================================
    #           Caching
    # ================================

    def get_cached_result(key)
      cached = @cache[key]
      return nil unless cached
      return nil if cached[:expires_at] < Time.current

      Rails.logger.debug "[YahooFinance] Cache hit for #{key}"
      cached[:data]
    end

    def cache_result(key, data)
      @cache[key] = {
        data: data,
        expires_at: Time.current + CACHE_DURATION
      }
      clean_expired_cache
    end

    def clean_expired_cache
      @cache.reject! { |_, cached| cached[:expires_at] < Time.current }
    end

    # ================================
    #         Helper Methods
    # ================================

    def generate_same_currency_rates(from, to, start_date, end_date)
      (start_date..end_date).map do |date|
        Rate.new(date: date, from: from, to: to, rate: 1.0)
      end
    end

    def fetch_currency_pair_data(from, to, start_date, end_date)
      symbol = "#{from}#{to}=X"
      fetch_chart_data(symbol, start_date, end_date) do |timestamp, close_rate|
        Rate.new(
          date: Time.at(timestamp).to_date,
          from: from,
          to: to,
          rate: close_rate.to_f
        )
      end
    end

    def fetch_inverse_currency_pair_data(from, to, start_date, end_date)
      symbol = "#{to}#{from}=X"
      rates = fetch_chart_data(symbol, start_date, end_date) do |timestamp, close_rate|
        Rate.new(
          date: Time.at(timestamp).to_date,
          from: from,
          to: to,
          rate: (1.0 / close_rate.to_f).round(8)
        )
      end

      Rails.logger.debug "[YahooFinance] Used inverse pair for #{from}/#{to}" if rates&.any?
      rates
    end

    def fetch_chart_data(symbol, start_date, end_date, &block)
      period1 = start_date.to_time.to_i
      period2 = end_date.end_of_day.to_time.to_i

      Rails.logger.debug "[YahooFinance] Requesting chart data for symbol: #{symbol}"

      begin
        response = client.get("#{base_url}/v8/finance/chart/#{symbol}") do |req|
          req.params["period1"] = period1
          req.params["period2"] = period2
          req.params["interval"] = "1d"
          req.params["includeAdjustedClose"] = true
        end

        data = JSON.parse(response.body)

        # Check for Yahoo Finance errors
        if data.dig("chart", "error")
          error_msg = data.dig("chart", "error", "description") || "Unknown Yahoo Finance error"
          Rails.logger.warn "[YahooFinance] API error for #{symbol}: #{error_msg}"
          return nil
        end

        chart_data = data.dig("chart", "result", 0)
        return nil unless chart_data

        timestamps = chart_data.dig("timestamp") || []
        quotes = chart_data.dig("indicators", "quote", 0) || {}
        closes = quotes["close"] || []

        results = []
        timestamps.each_with_index do |timestamp, index|
          close_value = closes[index]
          next if close_value.nil? || close_value <= 0

          results << block.call(timestamp, close_value)
        end

        results.sort_by(&:date)
      rescue Faraday::Error => e
        Rails.logger.warn "[YahooFinance] Request failed for #{symbol}: #{e.message}"
        nil
      end
    end

    def client
      @client ||= Faraday.new(url: base_url) do |faraday|
        faraday.request(:retry, {
          max: 3,
          interval: 0.1,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: [ Faraday::ConnectionFailed, Faraday::TimeoutError ]
        })

        faraday.request :json
        faraday.response :raise_error

        # Yahoo Finance requires common browser headers to avoid blocking
        faraday.headers["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        faraday.headers["Accept"] = "application/json"
        faraday.headers["Accept-Language"] = "en-US,en;q=0.9"
        faraday.headers["Cache-Control"] = "no-cache"
        faraday.headers["Pragma"] = "no-cache"

        # Set reasonable timeouts
        faraday.options.timeout = 10
        faraday.options.open_timeout = 5
      end
    end

    def map_country_code(exchange_name)
      return nil if exchange_name.blank?

      # Map common exchange names to country codes
      case exchange_name.upcase.strip
      when /NASDAQ|NYSE|AMEX|BATS|IEX/
        "US"
      when /TSX|TSXV|CSE/
        "CA"
      when /LSE|LONDON|AIM/
        "GB"
      when /TOKYO|TSE|NIKKEI|JASDAQ/
        "JP"
      when /ASX|AUSTRALIA/
        "AU"
      when /EURONEXT|PARIS|AMSTERDAM|BRUSSELS|LISBON/
        case exchange_name.upcase
        when /PARIS/ then "FR"
        when /AMSTERDAM/ then "NL"
        when /BRUSSELS/ then "BE"
        when /LISBON/ then "PT"
        else "FR" # Default to France for Euronext
        end
      when /FRANKFURT|XETRA|GETTEX/
        "DE"
      when /SIX|ZURICH/
        "CH"
      when /BME|MADRID/
        "ES"
      when /BORSA|MILAN/
        "IT"
      when /OSLO|OSE/
        "NO"
      when /STOCKHOLM|OMX/
        "SE"
      when /COPENHAGEN/
        "DK"
      when /HELSINKI/
        "FI"
      when /VIENNA/
        "AT"
      when /WARSAW|GPW/
        "PL"
      when /PRAGUE/
        "CZ"
      when /BUDAPEST/
        "HU"
      when /SHANGHAI|SHENZHEN/
        "CN"
      when /HONG\s*KONG|HKG/
        "HK"
      when /KOREA|KRX/
        "KR"
      when /SINGAPORE|SGX/
        "SG"
      when /MUMBAI|NSE|BSE/
        "IN"
      when /SAO\s*PAULO|BOVESPA/
        "BR"
      when /MEXICO|BMV/
        "MX"
      when /JSE|JOHANNESBURG/
        "ZA"
      else
        nil
      end
    end

    def map_exchange_mic(exchange_code)
      return nil if exchange_code.blank?

      # Map Yahoo exchange codes to MIC codes
      case exchange_code.upcase.strip
      when "NMS"
        "XNAS" # NASDAQ Global Select
      when "NGM"
        "XNAS" # NASDAQ Global Market
      when "NCM"
        "XNAS" # NASDAQ Capital Market
      when "NYQ"
        "XNYS" # NYSE
      when "PCX", "PSX"
        "ARCX" # NYSE Arca
      when "ASE", "AMX"
        "XASE" # NYSE American
      when "YHD"
        "XNAS" # Yahoo default, assume NASDAQ
      when "TSE", "TOR"
        "XTSE" # Toronto Stock Exchange
      when "CVE"
        "XTSX" # TSX Venture Exchange
      when "LSE", "LON"
        "XLON" # London Stock Exchange
      when "FRA"
        "XFRA" # Frankfurt Stock Exchange
      when "PAR"
        "XPAR" # Euronext Paris
      when "AMS"
        "XAMS" # Euronext Amsterdam
      when "BRU"
        "XBRU" # Euronext Brussels
      when "SWX"
        "XSWX" # SIX Swiss Exchange
      when "HKG"
        "XHKG" # Hong Kong Stock Exchange
      when "TYO"
        "XJPX" # Japan Exchange Group
      when "ASX"
        "XASX" # Australian Securities Exchange
      else
        exchange_code.upcase
      end
    end

    def map_security_type(quote_type)
      case quote_type&.downcase
      when "equity"
        "common stock"
      when "etf"
        "etf"
      when "mutualfund"
        "mutual fund"
      when "index"
        "index"
      else
        quote_type&.downcase
      end
    end

    # Override default error transformer to handle Yahoo Finance specific errors
    def default_error_transformer(error)
      case error
      when Faraday::TooManyRequestsError
        Rails.logger.warn "[YahooFinance] Rate limit exceeded: #{error.message}"
        RateLimitError.new("Yahoo Finance rate limit exceeded", details: error.response&.dig(:body))
      when Faraday::Error
        Rails.logger.error "[YahooFinance] Faraday error: #{error.message}"
        Error.new(
          error.message,
          details: error.response&.dig(:body)
        )
      else
        Rails.logger.error "[YahooFinance] Generic error: #{error.message}"
        Error.new(error.message)
      end
    end
end
