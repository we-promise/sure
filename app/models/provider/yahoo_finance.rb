class Provider::YahooFinance < Provider
  include ExchangeRateConcept, SecurityConcept
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::YahooFinance::Error
  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)
  AuthenticationError = Class.new(Error)
  InvalidSymbolError = Class.new(Error)
  MarketClosedError = Class.new(Error)

  # Cache duration for repeated requests (5 minutes)
  CACHE_DURATION = 5.minutes

  # Maximum cache duration for cookie/crumb authentication
  # Even if cookie has longer expiry, cap it to avoid stale crumbs
  MAX_CRUMB_CACHE_DURATION = 1.hour

  # Maximum lookback window for historical data (configurable)
  MAX_LOOKBACK_WINDOW = 10.years

  # Minimum delay between requests to avoid rate limiting (in seconds)
  MIN_REQUEST_INTERVAL = 0.5

  # Pool of modern browser user-agents to rotate through
  # Based on https://github.com/ranaroussi/yfinance/pull/2277
  USER_AGENTS = [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0"
  ].freeze

  def initialize
    # Yahoo Finance doesn't require an API key but we may want to add proxy support later
    @cache_prefix = "yahoo_finance"
  end

  def healthy?
    begin
      # Test with a known stable ticker (Apple)
      response = client.get("#{base_url}/v8/finance/chart/AAPL") do |req|
        req.params["interval"] = "1d"
        req.params["range"] = "1d"
      end

      data = JSON.parse(response.body)
      result = data.dig("chart", "result")
      health_status = result.present? && result.any?

      health_status
    rescue => e
      false
    end
  end

  def usage
    # Yahoo Finance doesn't expose usage data, so we return a mock structure
    with_provider_response do
      usage_data = UsageData.new(
        used: 0,
        limit: 2000, # Estimated daily limit based on community knowledge
        utilization: 0,
        plan: "Free"
      )

      usage_data
    end
  end

  # ================================
  #          Exchange Rates
  # ================================

  def fetch_exchange_rate(from:, to:, date:)
    with_provider_response do
      # Return 1.0 if same currency
      if from == to
        Rate.new(date: date, from: from, to: to, rate: 1.0)
      else
        cache_key = "exchange_rate_#{from}_#{to}_#{date}"
        if cached_result = get_cached_result(cache_key)
          cached_result
        else
          # For a single date, we'll fetch a range and find the closest match
          end_date = date
          start_date = date - 10.days # Extended range for better coverage

          rates_response = fetch_exchange_rates(
            from: from,
            to: to,
            start_date: start_date,
            end_date: end_date
          )

          raise Error, "Failed to fetch exchange rates: #{rates_response.error.message}" unless rates_response.success?

          rates = rates_response.data
          if rates.length == 1
            rates.first
          else
            # Find the exact date or the closest previous date
            target_rate = rates.find { |r| r.date == date } ||
                         rates.select { |r| r.date <= date }.max_by(&:date)

            raise Error, "No exchange rate found for #{from}/#{to} on or before #{date}" unless target_rate

            cache_result(cache_key, target_rate)
            target_rate
          end
        end
      end
    end
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    with_provider_response do
      validate_date_range!(start_date, end_date)
      # Return 1.0 rates if same currency
      if from == to
        generate_same_currency_rates(from, to, start_date, end_date)
      else
        cache_key = "exchange_rates_#{from}_#{to}_#{start_date}_#{end_date}"
        if cached_result = get_cached_result(cache_key)
          cached_result
        else
          # Try both direct and inverse currency pairs
          rates = fetch_currency_pair_data(from, to, start_date, end_date) ||
                  fetch_inverse_currency_pair_data(from, to, start_date, end_date)

          raise Error, "No chart data found for currency pair #{from}/#{to}" unless rates&.any?

          cache_result(cache_key, rates)
          rates
        end
      end
    rescue JSON::ParserError => e
      raise Error, "Invalid response format: #{e.message}"
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      cache_key = "search_#{symbol}_#{country_code}_#{exchange_operating_mic}"
      if cached_result = get_cached_result(cache_key)
        cached_result
      else
        throttle_request
        response = client.get("#{base_url}/v1/finance/search") do |req|
          req.params["q"] = symbol.strip.upcase
          req.params["quotesCount"] = 25
        end

        data = JSON.parse(response.body)
        quotes = data.dig("quotes") || []

        securities = quotes.filter_map do |quote|
          Security.new(
            symbol: quote["symbol"],
            name: quote["longname"] || quote["shortname"] || quote["symbol"],
            logo_url: nil, # Yahoo search doesn't provide logos
            exchange_operating_mic: map_exchange_mic(quote["exchange"]),
            country_code: map_country_code(quote["exchDisp"])
          )
        end

        cache_result(cache_key, securities)
        securities
      end
    rescue JSON::ParserError => e
      raise Error, "Invalid search response format: #{e.message}"
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      # quoteSummary endpoint requires cookie/crumb authentication
      throttle_request
      cookie, crumb = fetch_cookie_and_crumb

      response = authenticated_client(cookie).get("#{base_url}/v10/finance/quoteSummary/#{symbol}") do |req|
        req.params["modules"] = "assetProfile,price,quoteType"
        req.params["crumb"] = crumb
      end

      data = JSON.parse(response.body)

      # Check for auth errors in response body
      if data.dig("quoteSummary", "error", "code") == "Unauthorized"
        # Clear cached crumb and retry once
        clear_crumb_cache
        cookie, crumb = fetch_cookie_and_crumb
        response = authenticated_client(cookie).get("#{base_url}/v10/finance/quoteSummary/#{symbol}") do |req|
          req.params["modules"] = "assetProfile,price,quoteType"
          req.params["crumb"] = crumb
        end
        data = JSON.parse(response.body)
      end

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

      security_info
    rescue JSON::ParserError => e
      raise Error, "Invalid response format: #{e.message}"
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      cache_key = "security_price_#{symbol}_#{exchange_operating_mic}_#{date}"
      if cached_result = get_cached_result(cache_key)
        cached_result
      else
        # For a single date, we'll fetch a range and find the closest match
        end_date = date
        start_date = date - 10.days # Extended range for better coverage

        prices_response = fetch_security_prices(
          symbol: symbol,
          exchange_operating_mic: exchange_operating_mic,
          start_date: start_date,
          end_date: end_date
        )

        raise Error, "Failed to fetch security prices: #{prices_response.error.message}" unless prices_response.success?

        prices = prices_response.data
        if prices.length == 1
          target_price = prices.first
        else
          # Find the exact date or the closest previous date
          target_price = prices.find { |p| p.date == date } ||
                        prices.select { |p| p.date <= date }.max_by(&:date)

          raise Error, "No price found for #{symbol} on or before #{date}" unless target_price
        end

        cache_result(cache_key, target_price)
        target_price
      end
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      validate_date_params!(start_date, end_date)
      # Convert dates to Unix timestamps using UTC to ensure consistent epoch boundaries across timezones
      period1 = start_date.to_time.utc.to_i
      period2 = end_date.end_of_day.to_time.utc.to_i

      throttle_request
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
      raw_currency = chart_data.dig("meta", "currency") || "USD"

      prices = []
      timestamps.each_with_index do |timestamp, index|
        close_price = closes[index]
        next if close_price.nil? # Skip days with no data (weekends, holidays)

        # Normalize currency and price to handle minor units
        normalized_currency, normalized_price = normalize_currency_and_price(raw_currency, close_price.to_f)

        prices << Price.new(
          symbol: symbol,
          date: Time.at(timestamp).utc.to_date,
          price: normalized_price,
          currency: normalized_currency,
          exchange_operating_mic: exchange_operating_mic
        )
      end

      sorted_prices = prices.sort_by(&:date)
      sorted_prices
    rescue JSON::ParserError => e
      raise Error, "Invalid response format: #{e.message}"
    end
  end

  private

    def base_url
      ENV["YAHOO_FINANCE_URL"] || "https://query1.finance.yahoo.com"
    end

    # ================================
    #      Currency Normalization
    # ================================

    # Yahoo Finance sometimes returns currencies in minor units (pence, cents)
    # This is not part of ISO 4217 but is a convention used by financial data providers
    # Mapping of Yahoo Finance minor unit codes to standard currency codes and conversion multipliers
    MINOR_CURRENCY_CONVERSIONS = {
      "GBp" => { currency: "GBP", multiplier: 0.01 },  # British pence to pounds (eg. https://finance.yahoo.com/quote/IITU.L/)
      "ZAc" => { currency: "ZAR", multiplier: 0.01 }   # South African cents to rand (eg. https://finance.yahoo.com/quote/JSE.JO)
    }.freeze

    # Normalizes Yahoo Finance currency codes and prices
    # Returns [currency_code, price] with currency converted to standard ISO code
    # and price converted from minor units to major units if applicable
    def normalize_currency_and_price(currency, price)
      if conversion = MINOR_CURRENCY_CONVERSIONS[currency]
        [ conversion[:currency], price * conversion[:multiplier] ]
      else
        [ currency, price ]
      end
    end

    # ================================
    #           Validation
    # ================================


    def validate_date_range!(start_date, end_date)
      raise Error, "Start date cannot be after end date" if start_date > end_date
      raise Error, "Date range too large (max 5 years)" if end_date > start_date + 5.years
    end

    def validate_date_params!(start_date, end_date)
      # Validate presence and coerce to dates
      validated_start_date = validate_and_coerce_date!(start_date, "start_date")
      validated_end_date = validate_and_coerce_date!(end_date, "end_date")

      # Ensure start_date <= end_date
      if validated_start_date > validated_end_date
        error_msg = "Start date (#{validated_start_date}) cannot be after end date (#{validated_end_date})"
        raise ArgumentError, error_msg
      end

      # Ensure end_date is not in the future
      today = Date.current
      if validated_end_date > today
        error_msg = "End date (#{validated_end_date}) cannot be in the future"
        raise ArgumentError, error_msg
      end

      # Optional: Enforce max lookback window (configurable via constant)
      max_lookback = MAX_LOOKBACK_WINDOW.ago.to_date
      if validated_start_date < max_lookback
        error_msg = "Start date (#{validated_start_date}) exceeds maximum lookback window (#{max_lookback})"
        raise ArgumentError, error_msg
      end
    end

    def validate_and_coerce_date!(date_param, param_name)
      # Check presence
      if date_param.blank?
        error_msg = "#{param_name} cannot be blank"
        raise ArgumentError, error_msg
      end

      # Try to coerce to date
      begin
        if date_param.respond_to?(:to_date)
          date_param.to_date
        else
          Date.parse(date_param.to_s)
        end
      rescue ArgumentError => e
        error_msg = "Invalid #{param_name}: #{date_param} (#{e.message})"
        raise ArgumentError, error_msg
      end
    end

    # ================================
    #           Caching
    # ================================

    def get_cached_result(key)
      full_key = "#{@cache_prefix}_#{key}"
      data = Rails.cache.read(full_key)
      data
    end

    def cache_result(key, data)
      full_key = "#{@cache_prefix}_#{key}"
      Rails.cache.write(full_key, data, expires_in: CACHE_DURATION)
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
          date: Time.at(timestamp).utc.to_date,
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
          date: Time.at(timestamp).utc.to_date,
          from: from,
          to: to,
          rate: (1.0 / close_rate.to_f).round(8)
        )
      end

      rates
    end

    def fetch_chart_data(symbol, start_date, end_date, &block)
      period1 = start_date.to_time.utc.to_i
      period2 = end_date.end_of_day.to_time.utc.to_i

      begin
        throttle_request
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
        nil
      end
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.request(:retry, {
          max: max_retries,
          interval: retry_interval,
          interval_randomness: 0.5,
          backoff_factor: 2,
          retry_statuses: [ 429 ],
          exceptions: [ Faraday::ConnectionFailed, Faraday::TimeoutError ]
        })

        faraday.request :json
        faraday.response :raise_error

        # Yahoo Finance requires common browser headers to avoid blocking
        # Rotate user-agents to reduce rate limiting (based on yfinance PR #2277)
        faraday.headers["User-Agent"] = random_user_agent
        faraday.headers["Accept"] = "application/json"
        faraday.headers["Accept-Language"] = "en-US,en;q=0.9"
        faraday.headers["Cache-Control"] = "no-cache"
        faraday.headers["Pragma"] = "no-cache"

        # Set reasonable timeouts
        faraday.options.timeout = 10
        faraday.options.open_timeout = 5
      end
    end

    def random_user_agent
      USER_AGENTS.sample
    end

    def max_retries
      ENV.fetch("YAHOO_FINANCE_MAX_RETRIES", 5).to_i
    end

    def retry_interval
      ENV.fetch("YAHOO_FINANCE_RETRY_INTERVAL", 1.0).to_f
    end

    def min_request_interval
      ENV.fetch("YAHOO_FINANCE_MIN_REQUEST_INTERVAL", MIN_REQUEST_INTERVAL).to_f
    end

    def throttle_request
      @last_request_time ||= Time.at(0)
      elapsed = Time.current - @last_request_time
      sleep_time = min_request_interval - elapsed
      sleep(sleep_time) if sleep_time > 0
      @last_request_time = Time.current
    end

    # ================================
    #    Cookie/Crumb Authentication
    # ================================

    # Fetches and caches the Yahoo Finance cookie and crumb for authenticated endpoints
    # The crumb is a CSRF token required by some Yahoo Finance endpoints (e.g., quoteSummary)
    def fetch_cookie_and_crumb
      cache_key = "#{@cache_prefix}_auth_crumb"
      cached = Rails.cache.read(cache_key)
      return cached if cached.present?

      # Step 1: Get cookie from Yahoo Finance
      cookie_response = auth_client.get("https://fc.yahoo.com")
      cookie = extract_cookie(cookie_response)
      cookie_max_age = extract_cookie_max_age(cookie_response)

      raise AuthenticationError, "Failed to obtain Yahoo Finance cookie" if cookie.blank?

      # Step 2: Get crumb using the cookie
      crumb_response = auth_client.get("#{base_url}/v1/test/getcrumb") do |req|
        req.headers["Cookie"] = cookie
      end

      crumb = crumb_response.body.strip

      raise AuthenticationError, "Failed to obtain Yahoo Finance crumb" if crumb.blank?

      # Cache the cookie/crumb pair using cookie's max-age, capped at MAX_CRUMB_CACHE_DURATION
      cache_duration = [ cookie_max_age || MAX_CRUMB_CACHE_DURATION, MAX_CRUMB_CACHE_DURATION ].min
      result = [ cookie, crumb ]
      Rails.cache.write(cache_key, result, expires_in: cache_duration)
      result
    rescue Faraday::Error => e
      raise AuthenticationError, "Failed to authenticate with Yahoo Finance: #{e.message}"
    end

    def clear_crumb_cache
      Rails.cache.delete("#{@cache_prefix}_auth_crumb")
    end

    # Extract the authentication cookie from Yahoo Finance response
    def extract_cookie(response)
      set_cookie = response.headers["set-cookie"]
      return nil if set_cookie.blank?

      # Extract the cookie value (format: "A3=d=xxx&S=xxx; Max-Age=31557600; ...")
      # We only need the part before the first semicolon
      set_cookie.split(";").first
    end

    # Extract Max-Age from cookie header and convert to seconds
    # Format: "...; Max-Age=31557600; ..."
    def extract_cookie_max_age(response)
      set_cookie = response.headers["set-cookie"]
      return nil if set_cookie.blank?

      max_age_match = set_cookie.match(/Max-Age=(\d+)/i)
      return nil unless max_age_match

      max_age_match[1].to_i.seconds
    end

    # Client for authentication requests (no error raising - fc.yahoo.com returns 404 but sets cookie)
    def auth_client
      @auth_client ||= Faraday.new(ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.headers["User-Agent"] = random_user_agent
        faraday.headers["Accept"] = "*/*"
        faraday.headers["Accept-Language"] = "en-US,en;q=0.9"
        faraday.options.timeout = 10
        faraday.options.open_timeout = 5
      end
    end

    # Client for authenticated requests (includes cookie header)
    def authenticated_client(cookie)
      Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.request(:retry, {
          max: max_retries,
          interval: retry_interval,
          interval_randomness: 0.5,
          backoff_factor: 2,
          retry_statuses: [ 429 ],
          exceptions: [ Faraday::ConnectionFailed, Faraday::TimeoutError ]
        })

        faraday.request :json
        faraday.response :raise_error

        faraday.headers["User-Agent"] = random_user_agent
        faraday.headers["Accept"] = "application/json"
        faraday.headers["Accept-Language"] = "en-US,en;q=0.9"
        faraday.headers["Cache-Control"] = "no-cache"
        faraday.headers["Pragma"] = "no-cache"
        faraday.headers["Cookie"] = cookie

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
        RateLimitError.new("Yahoo Finance rate limit exceeded", details: error.response&.dig(:body))
      when Faraday::UnauthorizedError
        # 401 indicates missing or invalid crumb/cookie authentication
        AuthenticationError.new("Yahoo Finance authentication failed (invalid crumb)", details: error.response&.dig(:body))
      when AuthenticationError
        # Already an authentication error, return as is
        error
      when Faraday::Error
        Error.new(
          error.message,
          details: error.response&.dig(:body)
        )
      when Error
        # Already a Yahoo Finance error, return as is
        error
      else
        Error.new(error.message)
      end
    end
end
