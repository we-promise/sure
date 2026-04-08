class Provider::Finnhub < Provider
  include SecurityConcept
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Finnhub::Error
  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  # Minimum delay between requests to avoid rate limiting (in seconds)
  MIN_REQUEST_INTERVAL = 0.1

  # MIC (Market Identifier Code) to Finnhub exchange suffix mapping
  MIC_TO_FINNHUB_SUFFIX = {
    "XNYS" => "",      # NYSE
    "XNAS" => "",      # NASDAQ
    "XLON" => ".L",    # London
    "XETR" => ".DE",   # XETRA/Frankfurt
    "XTSE" => ".TO",   # Toronto
    "XTKS" => ".T",    # Tokyo
    "XHKG" => ".HK",   # Hong Kong
    "XASX" => ".AX",   # Australia
    "XPAR" => ".PA",   # Paris
    "XAMS" => ".AS",   # Amsterdam
    "XSWX" => ".SW",   # Swiss
    "XMIL" => ".MI",   # Milan
    "XMAD" => ".MC",   # Madrid
    "XKRX" => ".KS",   # Korea
    "XBOM" => ".BO",   # Bombay/BSE
    "XNSE" => ".NS"   # NSE India
  }.freeze

  # Exchange suffix to currency mapping for candle data (which doesn't include currency)
  EXCHANGE_SUFFIX_CURRENCY = {
    "" => "USD",
    ".L" => "GBP",
    ".DE" => "EUR",
    ".TO" => "CAD",
    ".T" => "JPY",
    ".HK" => "HKD",
    ".AX" => "AUD",
    ".PA" => "EUR",
    ".AS" => "EUR",
    ".SW" => "CHF",
    ".MI" => "EUR",
    ".MC" => "EUR",
    ".KS" => "KRW",
    ".BO" => "INR",
    ".NS" => "INR"
  }.freeze

  def initialize(api_key)
    @api_key = api_key
  end

  def healthy?
    with_provider_response do
      response = client.get("#{base_url}/api/v1/stock/profile2") do |req|
        req.params["symbol"] = "AAPL"
      end

      parsed = JSON.parse(response.body)
      parsed.dig("name").present?
    end
  end

  def usage
    with_provider_response do
      UsageData.new(
        used: nil,
        limit: 60,
        utilization: nil,
        plan: "Free",
      )
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      throttle_request
      response = client.get("#{base_url}/api/v1/search") do |req|
        req.params["q"] = symbol
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)
      results = parsed.dig("result")

      if results.nil?
        raise Error, "No data returned from search"
      end

      results.map do |security|
        Security.new(
          symbol: security.dig("symbol"),
          name: security.dig("description"),
          logo_url: nil,
          exchange_operating_mic: nil,
          country_code: nil,
        )
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      fh_symbol = finnhub_symbol(symbol, exchange_operating_mic)

      throttle_request
      response = client.get("#{base_url}/api/v1/stock/profile2") do |req|
        req.params["symbol"] = fh_symbol
      end

      profile = JSON.parse(response.body)
      check_api_error!(profile)

      if profile.blank? || profile.dig("name").blank?
        raise Error, "No profile data returned for symbol #{fh_symbol}"
      end

      SecurityInfo.new(
        symbol: symbol,
        name: profile.dig("name"),
        links: profile.dig("weburl"),
        logo_url: profile.dig("logo"),
        description: profile.dig("finnhubIndustry"),
        kind: nil,
        exchange_operating_mic: exchange_operating_mic,
      )
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      historical_data = fetch_security_prices(symbol:, exchange_operating_mic:, start_date: date, end_date: date)

      raise ProviderError, "No prices found for security #{symbol} on date #{date}" if historical_data.data.empty?

      historical_data.data.first
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      fh_symbol = finnhub_symbol(symbol, exchange_operating_mic)
      currency = currency_for_symbol(fh_symbol, exchange_operating_mic)

      throttle_request
      response = client.get("#{base_url}/api/v1/stock/candle") do |req|
        req.params["symbol"] = fh_symbol
        req.params["resolution"] = "D"
        req.params["from"] = start_date.to_time.to_i
        req.params["to"] = end_date.to_time.to_i
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      status = parsed.dig("s")

      if status == "no_data"
        return []
      end

      if status != "ok"
        raise InvalidSecurityPriceError, "Unexpected candle status: #{status}"
      end

      closes = parsed.dig("c") || []
      timestamps = parsed.dig("t") || []

      closes.zip(timestamps).map do |price, timestamp|
        if price.nil? || price.to_f <= 0
          date = Time.at(timestamp).to_date
          Rails.logger.warn("#{self.class.name} returned invalid price data for security #{symbol} on: #{date}. Price data: #{price.inspect}")
          next
        end

        Price.new(
          symbol: symbol,
          date: Time.at(timestamp).to_date,
          price: price,
          currency: currency,
          exchange_operating_mic: exchange_operating_mic,
        )
      end.compact
    end
  end

  private
    attr_reader :api_key

    def base_url
      ENV["FINNHUB_URL"] || "https://finnhub.io"
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
        faraday.headers["X-Finnhub-Token"] = api_key
      end
    end

    # Builds a Finnhub-formatted ticker symbol from a base symbol and optional MIC.
    # US exchanges use plain symbols (e.g., "AAPL"), while international exchanges
    # append a suffix (e.g., "SAP.DE" for XETRA).
    def finnhub_symbol(symbol, exchange_operating_mic)
      return symbol if exchange_operating_mic.blank?

      suffix = MIC_TO_FINNHUB_SUFFIX[exchange_operating_mic]
      return symbol if suffix.nil? || suffix.empty?

      # Avoid double-appending if the symbol already has the suffix
      return symbol if symbol.end_with?(suffix)

      "#{symbol}#{suffix}"
    end

    # Determines the trading currency for a symbol based on its exchange suffix.
    # Falls back to fetching the profile if the suffix is unknown.
    def currency_for_symbol(fh_symbol, exchange_operating_mic)
      suffix = if exchange_operating_mic.present?
        MIC_TO_FINNHUB_SUFFIX[exchange_operating_mic] || ""
      else
        # Extract suffix from symbol (e.g., ".DE" from "SAP.DE")
        fh_symbol.include?(".") ? ".#{fh_symbol.split('.', 2).last}" : ""
      end

      currency = EXCHANGE_SUFFIX_CURRENCY[suffix]
      return currency if currency.present?

      # Fallback: fetch profile to get currency
      fetch_currency_from_profile(fh_symbol)
    end

    # Fetches the currency for a symbol by calling the profile endpoint.
    # Used as a fallback when the exchange suffix is not in our mapping.
    def fetch_currency_from_profile(fh_symbol)
      throttle_request
      response = client.get("#{base_url}/api/v1/stock/profile2") do |req|
        req.params["symbol"] = fh_symbol
      end

      profile = JSON.parse(response.body)
      profile.dig("currency") || "USD"
    end

    # Paces API requests to stay within Finnhub's rate limits (60 req/min).
    # Sleeps inline because the API physically cannot be called faster.
    def throttle_request
      # Layer 1: Per-instance minimum interval between calls
      @last_request_time ||= Time.at(0)
      elapsed = Time.current - @last_request_time
      sleep_time = min_request_interval - elapsed
      sleep(sleep_time) if sleep_time > 0

      # Layer 2: Global per-minute counter via cache (Redis in prod).
      # Check current usage before incrementing to avoid exceeding the limit.
      minute_key = "finnhub:requests:#{Time.current.to_i / 60}"
      current_count = Rails.cache.read(minute_key).to_i

      if current_count + 1 > max_requests_per_minute
        wait_seconds = 60 - (Time.current.to_i % 60) + 1
        Rails.logger.info("Finnhub: #{current_count + 1}/#{max_requests_per_minute} requests this minute, waiting #{wait_seconds}s")
        sleep(wait_seconds)
      end

      # Charge the request to the minute it actually fires in
      active_minute_key = "finnhub:requests:#{Time.current.to_i / 60}"
      Rails.cache.increment(active_minute_key, 1, expires_in: 120.seconds)

      @last_request_time = Time.current
    end

    def min_request_interval
      ENV.fetch("FINNHUB_MIN_REQUEST_INTERVAL", MIN_REQUEST_INTERVAL).to_f
    end

    def max_requests_per_minute
      ENV.fetch("FINNHUB_MAX_REQUESTS_PER_MINUTE", 60).to_i
    end

    def check_api_error!(parsed)
      return unless parsed.is_a?(Hash) && parsed["error"].present?

      error_message = parsed["error"]

      if error_message.to_s.downcase.include?("rate limit") || error_message.to_s.downcase.include?("too many requests")
        raise RateLimitError, error_message
      end

      raise Error, "API error: #{error_message}"
    end

    def default_error_transformer(error)
      case error
      when RateLimitError
        error
      when Faraday::TooManyRequestsError
        RateLimitError.new("Finnhub rate limit exceeded", details: error.response&.dig(:body))
      when Faraday::Error
        self.class::Error.new(error.message, details: error.response&.dig(:body))
      else
        self.class::Error.new(error.message)
      end
    end
end
