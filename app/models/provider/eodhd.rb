class Provider::Eodhd < Provider
  include SecurityConcept
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Eodhd::Error
  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  # Minimum delay between requests to avoid rate limiting (in seconds)
  MIN_REQUEST_INTERVAL = 0.5

  # Maximum API calls per day (EODHD free/basic plans are very restrictive)
  MAX_REQUESTS_PER_DAY = 20

  # EODHD free tier provides ~1 year of EOD data
  def max_history_days
    365
  end

  # EODHD uses {SYMBOL}.{EXCHANGE} ticker format with its own exchange codes
  MIC_TO_EODHD_EXCHANGE = {
    "XNYS" => "US", "XNAS" => "US", "XASE" => "US",
    "XLON" => "LSE",
    "XETR" => "XETRA",
    "XTSE" => "TO",
    "XPAR" => "PA",
    "XAMS" => "AS",
    "XSWX" => "SW",
    "XHKG" => "HK",
    "XASX" => "AU",
    "XTKS" => "TSE",
    "XMIL" => "MI",
    "XMAD" => "MC",
    "XOSL" => "OL",
    "XHEL" => "HE",
    "XCSE" => "CO",
    "XSTO" => "ST",
    "XKRX" => "KS",
    "XBOM" => "BSE",
    "XNSE" => "NSE"
  }.freeze

  EODHD_EXCHANGE_TO_MIC = {
    "US" => "XNYS", "LSE" => "XLON", "XETRA" => "XETR",
    "TO" => "XTSE", "PA" => "XPAR", "AS" => "XAMS",
    "SW" => "XSWX", "HK" => "XHKG", "AU" => "XASX",
    "TSE" => "XTKS", "MI" => "XMIL", "MC" => "XMAD"
  }.freeze

  EODHD_COUNTRY_TO_CODE = {
    "USA" => "US", "UK" => "GB", "Germany" => "DE", "France" => "FR",
    "Netherlands" => "NL", "Switzerland" => "CH", "Canada" => "CA",
    "Japan" => "JP", "Australia" => "AU", "Hong Kong" => "HK"
  }.freeze

  EXCHANGE_CURRENCY = {
    "US" => "USD", "LSE" => "GBP", "XETRA" => "EUR", "TO" => "CAD",
    "PA" => "EUR", "AS" => "EUR", "SW" => "CHF", "HK" => "HKD",
    "AU" => "AUD", "TSE" => "JPY"
  }.freeze

  def initialize(api_key)
    @api_key = api_key # pipelock:ignore
  end

  def healthy?
    with_provider_response do
      response = client.get("#{base_url}/api/user") do |req|
        req.params["api_token"] = api_key
        req.params["fmt"] = "json"
      end

      JSON.parse(response.body).dig("name").present?
    end
  end

  def usage
    with_provider_response do
      response = client.get("#{base_url}/api/user") do |req|
        req.params["api_token"] = api_key
        req.params["fmt"] = "json"
      end

      parsed = JSON.parse(response.body)

      limit = parsed.dig("apiRequests").to_i
      daily_limit = parsed.dig("dailyRateLimit").to_i

      daily_key = daily_cache_key
      used = Rails.cache.read(daily_key).to_i

      UsageData.new(
        used: used,
        limit: daily_limit > 0 ? daily_limit : MAX_REQUESTS_PER_DAY,
        utilization: daily_limit > 0 ? (used.to_f / daily_limit * 100) : (used.to_f / MAX_REQUESTS_PER_DAY * 100),
        plan: parsed.dig("subscriptionType") || "unknown"
      )
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      enforce_daily_limit!
      throttle_request

      response = client.get("#{base_url}/api/search/#{CGI.escape(symbol)}") do |req|
        req.params["api_token"] = api_key
        req.params["fmt"] = "json"
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      unless parsed.is_a?(Array)
        raise Error, "Unexpected response format from search API"
      end

      parsed.map do |security|
        eodhd_exchange = security.dig("Exchange")
        mic = EODHD_EXCHANGE_TO_MIC[eodhd_exchange]
        country = EODHD_COUNTRY_TO_CODE[security.dig("Country")]
        code = security.dig("Code")
        currency = security.dig("Currency")

        # Cache the API-returned currency so fetch_security_prices can use it
        if currency.present? && mic.present?
          cache_key = "eodhd:currency:#{code.upcase}:#{mic}"
          Rails.cache.write(cache_key, currency, expires_in: 24.hours)
        end

        Security.new(
          symbol: code,
          name: security.dig("Name"),
          logo_url: nil,
          exchange_operating_mic: mic,
          country_code: country,
          currency: currency
        )
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      enforce_daily_limit!
      throttle_request

      ticker = eodhd_symbol(symbol, exchange_operating_mic)

      response = client.get("#{base_url}/api/fundamentals/#{ticker}") do |req|
        req.params["api_token"] = api_key
        req.params["fmt"] = "json"
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      general = parsed.dig("General") || {}

      SecurityInfo.new(
        symbol: symbol,
        name: general.dig("Name"),
        links: general.dig("WebURL"),
        logo_url: general.dig("LogoURL"),
        description: general.dig("Description"),
        kind: general.dig("Type"),
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
      enforce_daily_limit!
      throttle_request

      ticker = eodhd_symbol(symbol, exchange_operating_mic)

      response = client.get("#{base_url}/api/eod/#{ticker}") do |req|
        req.params["api_token"] = api_key
        req.params["fmt"] = "json"
        req.params["from"] = start_date.to_s
        req.params["to"] = end_date.to_s
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      unless parsed.is_a?(Array)
        raise InvalidSecurityPriceError, "Unexpected response format from EOD API"
      end

      # Prefer cached currency from search results; fall back to hardcoded map
      cache_key = "eodhd:currency:#{symbol.upcase}:#{exchange_operating_mic}"
      eodhd_exchange = MIC_TO_EODHD_EXCHANGE[exchange_operating_mic]
      currency = Rails.cache.read(cache_key) || EXCHANGE_CURRENCY[eodhd_exchange]

      parsed.map do |resp|
        price = resp.dig("close")
        date = resp.dig("date")

        if price.nil? || price.to_f <= 0
          Rails.logger.warn("#{self.class.name} returned invalid price data for security #{symbol} on: #{date}.  Price data: #{price.inspect}")
          next
        end

        Price.new(
          symbol: symbol,
          date: date.to_date,
          price: price,
          currency: currency,
          exchange_operating_mic: exchange_operating_mic
        )
      end.compact
    end
  end

  private
    attr_reader :api_key

    def base_url
      ENV["EODHD_URL"] || "https://eodhd.com"
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
      end
    end

    # Builds the EODHD ticker format: {SYMBOL}.{EXCHANGE}
    def eodhd_symbol(symbol, exchange_operating_mic)
      eodhd_exchange = MIC_TO_EODHD_EXCHANGE[exchange_operating_mic] if exchange_operating_mic.present?

      if eodhd_exchange.present?
        "#{symbol}.#{eodhd_exchange}"
      elsif exchange_operating_mic.present?
        "#{symbol}.#{exchange_operating_mic}"
      else
        "#{symbol}.US"
      end
    end

    # Cache key for tracking daily API usage
    def daily_cache_key
      "eodhd:daily:#{Date.current}"
    end

    # Enforces the daily rate limit. Raises RateLimitError if the limit is exhausted.
    # Uses atomic increment-then-check to avoid TOCTOU races between concurrent workers.
    def enforce_daily_limit!
      new_count = Rails.cache.increment(daily_cache_key, 1, expires_in: 24.hours).to_i

      if new_count > max_requests_per_day
        raise RateLimitError, "EODHD daily rate limit of #{max_requests_per_day} requests exhausted"
      end
    end

    # Paces API requests to stay within EODHD's rate limits. Sleeps inline
    # because the API physically cannot be called faster - this is unavoidable
    # with a rate-limited provider.
    def throttle_request
      @last_request_time ||= Time.at(0)
      elapsed = Time.current - @last_request_time
      sleep_time = min_request_interval - elapsed
      sleep(sleep_time) if sleep_time > 0

      @last_request_time = Time.current
    end

    def min_request_interval
      ENV.fetch("EODHD_MIN_REQUEST_INTERVAL", MIN_REQUEST_INTERVAL).to_f
    end

    def max_requests_per_day
      ENV.fetch("EODHD_MAX_REQUESTS_PER_DAY", MAX_REQUESTS_PER_DAY).to_i
    end

    def check_api_error!(parsed)
      return unless parsed.is_a?(Hash) && parsed["error"].present?

      raise Error, "API error: #{parsed["error"]}"
    end

    def default_error_transformer(error)
      case error
      when RateLimitError
        error
      when Faraday::TooManyRequestsError
        RateLimitError.new("EODHD rate limit exceeded", details: error.response&.dig(:body))
      when Faraday::Error
        self.class::Error.new(error.message, details: error.response&.dig(:body))
      else
        self.class::Error.new(error.message)
      end
    end
end
