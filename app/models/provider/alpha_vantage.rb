class Provider::AlphaVantage < Provider
  include SecurityConcept
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::AlphaVantage::Error
  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  # Minimum delay between requests to avoid rate limiting (in seconds)
  MIN_REQUEST_INTERVAL = 1.0

  # Maximum requests per day (Alpha Vantage free tier limit)
  MAX_REQUESTS_PER_DAY = 25

  # Free tier "compact" returns ~100 trading days (~140 calendar days).
  # "full" requires a paid plan.
  def max_history_days
    140
  end

  # MIC code to Alpha Vantage symbol suffix mapping
  MIC_TO_AV_SUFFIX = {
    "XNYS" => "", "XNAS" => "", "XASE" => "",
    "XLON" => ".LON",
    "XETR" => ".DEX",
    "XTSE" => ".TRT",
    "XPAR" => ".PAR",
    "XAMS" => ".AMS",
    "XSWX" => ".SWX",
    "XHKG" => ".HKG",
    "XASX" => ".ASX",
    "XMIL" => ".MIL",
    "XMAD" => ".BME",
    "XOSL" => ".OSL",
    "XSTO" => ".STO",
    "XCSE" => ".CPH",
    "XHEL" => ".HEL"
  }.freeze

  # Alpha Vantage symbol suffix to MIC code mapping (auto-generated from forward map)
  AV_SUFFIX_TO_MIC = MIC_TO_AV_SUFFIX
    .reject { |_, suffix| suffix.empty? }
    .each_with_object({}) { |(mic, suffix), h| h[suffix.delete(".")] = mic }
    .merge("FRK" => "XFRA") # FRK is not in the forward map (no MIC→FRK entry)
    .freeze

  # Alpha Vantage region names to ISO country codes
  AV_REGION_TO_COUNTRY = {
    "United States" => "US", "United Kingdom" => "GB",
    "Frankfurt" => "DE", "XETRA" => "DE",
    "Amsterdam" => "NL", "Paris/Brussels" => "FR",
    "Switzerland" => "CH", "Toronto" => "CA",
    "Brazil/Sao Paolo" => "BR"
  }.freeze

  def initialize(api_key)
    @api_key = api_key # pipelock:ignore
  end

  # Alpha Vantage has no non-quota endpoint — every API call counts against
  # the 25/day free-tier limit. Rather than burn a call, we just check that
  # the API key is configured.
  def healthy?
    with_provider_response do
      api_key.present?
    end
  end

  def usage
    with_provider_response do
      day_key = "alpha_vantage:daily:#{Date.current}"
      used = Rails.cache.read(day_key).to_i

      UsageData.new(
        used: used,
        limit: max_requests_per_day,
        utilization: (used.to_f / max_requests_per_day * 100).round(1),
        plan: "Free"
      )
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      throttle_request
      response = client.get("#{base_url}/query") do |req|
        req.params["function"] = "SYMBOL_SEARCH"
        req.params["keywords"] = symbol
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)
      data = parsed.dig("bestMatches")

      if data.nil?
        raise Error, "No data returned from search endpoint"
      end

      data.map do |match|
        av_ticker = match["1. symbol"]
        region = match["4. region"]
        currency = match["8. currency"]

        # Cache the API-returned currency so fetch_security_prices can use it
        # instead of relying solely on the hardcoded suffix→currency fallback
        if currency.present?
          cache_key = "alpha_vantage:currency:#{av_ticker.upcase}"
          Rails.cache.write(cache_key, currency, expires_in: 24.hours)
        end

        Security.new(
          symbol: strip_av_suffix(av_ticker),
          name: match["2. name"],
          logo_url: nil,
          exchange_operating_mic: extract_mic_from_symbol(av_ticker),
          country_code: AV_REGION_TO_COUNTRY[region] || country_code,
          currency: currency
        )
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      av_symbol = to_av_symbol(symbol, exchange_operating_mic)

      throttle_request
      response = client.get("#{base_url}/query") do |req|
        req.params["function"] = "GLOBAL_QUOTE"
        req.params["symbol"] = av_symbol
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)
      quote = parsed.dig("Global Quote")

      if quote.nil? || quote.empty?
        raise Error, "No data returned for symbol #{av_symbol}"
      end

      SecurityInfo.new(
        symbol: symbol,
        name: nil,
        links: nil,
        logo_url: nil,
        description: nil,
        kind: nil,
        exchange_operating_mic: exchange_operating_mic
      )
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      historical_data = fetch_security_prices(symbol:, exchange_operating_mic:, start_date: date, end_date: date)

      raise InvalidSecurityPriceError, "No prices found for security #{symbol} on date #{date}" if historical_data.data.empty?

      historical_data.data.first
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      av_symbol = to_av_symbol(symbol, exchange_operating_mic)

      throttle_request
      response = client.get("#{base_url}/query") do |req|
        req.params["function"] = "TIME_SERIES_DAILY"
        req.params["symbol"] = av_symbol
        req.params["outputsize"] = "compact"
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)
      time_series = parsed.dig("Time Series (Daily)")

      if time_series.nil?
        raise InvalidSecurityPriceError, "No time series data returned for symbol #{av_symbol}"
      end

      currency = infer_currency_from_symbol(av_symbol)

      time_series.filter_map do |date_str, values|
        date = Date.parse(date_str)
        next unless date >= start_date && date <= end_date

        price = values["4. close"]

        if price.nil? || price.to_f <= 0
          Rails.logger.warn("#{self.class.name} returned invalid price data for security #{symbol} on: #{date_str}.  Price data: #{price.inspect}")
          next
        end

        Price.new(
          symbol: symbol,
          date: date,
          price: price,
          currency: currency,
          exchange_operating_mic: exchange_operating_mic
        )
      end
    end
  end

  private
    attr_reader :api_key

    def base_url
      ENV["ALPHA_VANTAGE_URL"] || "https://www.alphavantage.co"
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.request(:retry, {
          max: 3,
          interval: 1.0,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        })

        faraday.request :json
        faraday.response :raise_error
        faraday.params["apikey"] = api_key
      end
    end

    # Paces API requests to stay within Alpha Vantage's rate limits. Sleeps inline
    # because the API physically cannot be called faster -- this is unavoidable
    # with a rate-limited provider.
    def throttle_request
      # Layer 1: Per-instance minimum interval between calls
      @last_request_time ||= Time.at(0)
      elapsed = Time.current - @last_request_time
      sleep_time = min_request_interval - elapsed
      sleep(sleep_time) if sleep_time > 0

      # Layer 2: Global per-day request counter via cache (Redis in prod).
      # Atomic increment-then-check avoids the TOCTOU of read-check-increment.
      day_key = "alpha_vantage:daily:#{Date.current}"
      new_count = Rails.cache.increment(day_key, 1, expires_in: 24.hours).to_i

      if new_count > max_requests_per_day
        Rails.logger.warn("AlphaVantage: daily request limit reached (#{new_count}/#{max_requests_per_day})")
        raise RateLimitError, "Alpha Vantage daily request limit reached (#{max_requests_per_day} per day)"
      end

      @last_request_time = Time.current
    end

    def min_request_interval
      ENV.fetch("ALPHA_VANTAGE_MIN_REQUEST_INTERVAL", MIN_REQUEST_INTERVAL).to_f
    end

    def max_requests_per_day
      ENV.fetch("ALPHA_VANTAGE_MAX_REQUESTS_PER_DAY", MAX_REQUESTS_PER_DAY).to_i
    end

    # Converts a symbol + MIC code to Alpha Vantage's ticker format
    def to_av_symbol(symbol, exchange_operating_mic)
      return symbol if exchange_operating_mic.blank?

      suffix = MIC_TO_AV_SUFFIX[exchange_operating_mic]
      return symbol if suffix.nil?
      return symbol if suffix.empty?

      # Avoid double-suffixing if the symbol already has the correct suffix
      return symbol if symbol.end_with?(suffix)

      "#{symbol}#{suffix}"
    end

    # Strips the Alpha Vantage exchange suffix to get the canonical ticker
    # e.g., "CSPX.LON" -> "CSPX", "AAPL" -> "AAPL"
    def strip_av_suffix(symbol)
      return symbol unless symbol.include?(".")

      parts = symbol.split(".", 2)
      AV_SUFFIX_TO_MIC.key?(parts.last) ? parts.first : symbol
    end

    # Extracts MIC code from Alpha Vantage symbol suffix (e.g., "CSPX.LON" -> "XLON")
    def extract_mic_from_symbol(symbol)
      return nil unless symbol.include?(".")

      suffix = symbol.split(".").last
      AV_SUFFIX_TO_MIC[suffix]
    end

    # Infers currency from the exchange suffix of an Alpha Vantage symbol.
    # Falls back to cached currency from search results if available.
    def infer_currency_from_symbol(av_symbol)
      cache_key = "alpha_vantage:currency:#{av_symbol.upcase}"
      cached = Rails.cache.read(cache_key)
      return cached if cached.present?

      # Default currency based on exchange suffix
      suffix = av_symbol.include?(".") ? av_symbol.split(".").last : nil

      currency = case suffix
      when "LON" then "GBP"
      when "DEX", "FRK" then "EUR"
      when "PAR", "AMS", "MIL", "BME", "HEL" then "EUR"
      when "TRT" then "CAD"
      when "SWX" then "CHF"
      when "HKG" then "HKD"
      when "ASX" then "AUD"
      when "STO" then "SEK"
      when "CPH" then "DKK"
      when "OSL" then "NOK"
      else "USD"
      end

      Rails.cache.write(cache_key, currency, expires_in: 24.hours)
      currency
    end

    # Checks for Alpha Vantage-specific error responses.
    # Alpha Vantage returns errors as JSON keys rather than HTTP status codes.
    def check_api_error!(parsed)
      return unless parsed.is_a?(Hash)

      # Rate limit: Alpha Vantage returns a "Note" key when rate-limited
      if parsed["Note"].present?
        Rails.logger.warn("AlphaVantage rate limit: #{parsed["Note"]}")
        raise RateLimitError, parsed["Note"]
      end

      # General info/limit messages
      if parsed["Information"].present?
        Rails.logger.warn("AlphaVantage info: #{parsed["Information"]}")
        raise RateLimitError, parsed["Information"]
      end

      # Explicit error messages for invalid parameters
      if parsed["Error Message"].present?
        raise Error, "API error: #{parsed["Error Message"]}"
      end
    end

    def default_error_transformer(error)
      case error
      when RateLimitError
        error
      when Faraday::TooManyRequestsError
        RateLimitError.new("Alpha Vantage rate limit exceeded", details: error.response&.dig(:body))
      when Faraday::Error
        self.class::Error.new(error.message, details: error.response&.dig(:body))
      else
        self.class::Error.new(error.message)
      end
    end
end
