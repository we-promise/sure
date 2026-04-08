class Provider::Fmp < Provider
  include SecurityConcept
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Fmp::Error
  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  # Minimum delay between requests to avoid rate limiting (in seconds)
  MIN_REQUEST_INTERVAL = 0.25

  # Daily request limit for the free tier
  DAILY_REQUEST_LIMIT = 250

  # Warning threshold as a percentage of daily limit
  DAILY_LIMIT_WARNING_THRESHOLD = 0.8

  # ================================
  #    Exchange / MIC Mappings
  # ================================

  MIC_TO_FMP_SUFFIX = {
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
    "XNSE" => ".NS",   # NSE India
    "XOSL" => ".OL",   # Oslo
    "XHEL" => ".HE",   # Helsinki
    "XCSE" => ".CO",   # Copenhagen
    "XSTO" => ".ST"   # Stockholm
  }.freeze

  FMP_EXCHANGE_TO_MIC = {
    "NASDAQ" => "XNAS",
    "NYSE" => "XNYS",
    "AMEX" => "XASE",
    "LSE" => "XLON",
    "XETRA" => "XETR",
    "TSX" => "XTSE",
    "Euronext" => "XPAR",
    "SIX" => "XSWX",
    "HKSE" => "XHKG",
    "ASX" => "XASX"
  }.freeze

  FMP_EXCHANGE_TO_COUNTRY = {
    "NASDAQ" => "US",
    "NYSE" => "US",
    "AMEX" => "US",
    "LSE" => "GB",
    "XETRA" => "DE",
    "TSX" => "CA",
    "Euronext" => "FR",
    "SIX" => "CH",
    "HKSE" => "HK",
    "ASX" => "AU"
  }.freeze

  EXCHANGE_MIC_CURRENCY = {
    "XNYS" => "USD",
    "XNAS" => "USD",
    "XASE" => "USD",
    "XLON" => "GBP",
    "XETR" => "EUR",
    "XTSE" => "CAD",
    "XTKS" => "JPY",
    "XHKG" => "HKD",
    "XASX" => "AUD",
    "XPAR" => "EUR",
    "XAMS" => "EUR",
    "XSWX" => "CHF",
    "XMIL" => "EUR",
    "XMAD" => "EUR",
    "XKRX" => "KRW",
    "XBOM" => "INR",
    "XNSE" => "INR",
    "XOSL" => "NOK",
    "XHEL" => "EUR",
    "XCSE" => "DKK",
    "XSTO" => "SEK"
  }.freeze

  def initialize(api_key)
    @api_key = api_key
  end

  def healthy?
    with_provider_response do
      response = client.get("#{base_url}/api/v3/profile/AAPL") do |req|
        req.params["apikey"] = api_key
      end

      parsed = JSON.parse(response.body)
      parsed.is_a?(Array) && parsed.first&.dig("symbol").present?
    end
  end

  def usage
    with_provider_response do
      daily_key = "fmp:daily:#{Date.current}"
      used = Rails.cache.read(daily_key).to_i

      UsageData.new(
        used: used,
        limit: DAILY_REQUEST_LIMIT,
        utilization: (used.to_f / DAILY_REQUEST_LIMIT * 100).round(2),
        plan: "FMP"
      )
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      throttle_request
      response = client.get("#{base_url}/api/v3/search") do |req|
        req.params["query"] = symbol
        req.params["limit"] = 20
        req.params["apikey"] = api_key
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      unless parsed.is_a?(Array)
        raise Error, "Unexpected response format from FMP search"
      end

      parsed.map do |result|
        exchange_short = result["exchangeShortName"]

        Security.new(
          symbol: result["symbol"],
          name: result["name"],
          logo_url: nil,
          exchange_operating_mic: FMP_EXCHANGE_TO_MIC[exchange_short],
          country_code: FMP_EXCHANGE_TO_COUNTRY[exchange_short]
        )
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      ticker = fmp_symbol(symbol, exchange_operating_mic)

      throttle_request
      response = client.get("#{base_url}/api/v3/profile/#{ticker}") do |req|
        req.params["apikey"] = api_key
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      profile = parsed.is_a?(Array) ? parsed.first : parsed

      raise Error, "No security info found for #{symbol}" unless profile&.dig("symbol").present?

      SecurityInfo.new(
        symbol: symbol,
        name: profile["companyName"],
        links: profile["website"],
        logo_url: profile["image"],
        description: profile["description"],
        kind: profile["sector"],
        exchange_operating_mic: exchange_operating_mic
      )
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      historical_data = fetch_security_prices(symbol:, exchange_operating_mic:, start_date: date, end_date: date)

      raise Error, "No prices found for security #{symbol} on date #{date}" if historical_data.data.empty?

      historical_data.data.first
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      ticker = fmp_symbol(symbol, exchange_operating_mic)
      currency = infer_currency(exchange_operating_mic)

      throttle_request
      response = client.get("#{base_url}/api/v3/historical-price-full/#{ticker}") do |req|
        req.params["from"] = start_date.to_s
        req.params["to"] = end_date.to_s
        req.params["apikey"] = api_key
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      historical = parsed.dig("historical")

      if historical.nil?
        error_message = parsed.dig("Error Message") || "No historical data returned"
        raise InvalidSecurityPriceError, "API error: #{error_message}"
      end

      historical.filter_map do |entry|
        price = entry["close"]
        date = entry["date"]

        if price.nil? || price.to_f <= 0
          Rails.logger.warn("#{self.class.name} returned invalid price data for security #{symbol} on: #{date}. Price data: #{price.inspect}")
          next
        end

        Price.new(
          symbol: symbol,
          date: Date.parse(date),
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
      ENV["FMP_URL"] || "https://financialmodelingprep.com"
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

    # Builds the FMP-formatted ticker symbol with exchange suffix for international markets
    def fmp_symbol(symbol, exchange_operating_mic)
      return symbol if exchange_operating_mic.blank?

      suffix = MIC_TO_FMP_SUFFIX[exchange_operating_mic]
      return symbol if suffix.nil? || suffix.empty?

      "#{symbol}#{suffix}"
    end

    # Infers the trading currency from the exchange MIC code
    def infer_currency(exchange_operating_mic)
      EXCHANGE_MIC_CURRENCY.fetch(exchange_operating_mic, "USD")
    end

    # Paces API requests to stay within FMP's rate limits.
    # FMP has a very restrictive 250 requests/day limit on the free tier,
    # so we track daily usage and warn when approaching the limit.
    def throttle_request
      # Layer 1: Per-instance minimum interval between calls
      @last_request_time ||= Time.at(0)
      elapsed = Time.current - @last_request_time
      sleep_time = min_request_interval - elapsed
      sleep(sleep_time) if sleep_time > 0

      # Layer 2: Global daily request counter via cache (Redis in prod)
      daily_key = "fmp:daily:#{Date.current}"
      current_count = Rails.cache.read(daily_key).to_i

      if current_count >= DAILY_REQUEST_LIMIT
        raise RateLimitError, "FMP daily request limit (#{DAILY_REQUEST_LIMIT}) exceeded"
      end

      if current_count >= (DAILY_REQUEST_LIMIT * DAILY_LIMIT_WARNING_THRESHOLD).to_i
        Rails.logger.warn("FMP: Approaching daily limit - #{current_count}/#{DAILY_REQUEST_LIMIT} requests used")
      end

      Rails.cache.increment(daily_key, 1, expires_in: 24.hours)

      @last_request_time = Time.current
    end

    def min_request_interval
      ENV.fetch("FMP_MIN_REQUEST_INTERVAL", MIN_REQUEST_INTERVAL).to_f
    end

    def check_api_error!(parsed)
      if parsed.is_a?(Hash) && parsed["Error Message"].present?
        raise Error, "API error: #{parsed["Error Message"]}"
      end

      if parsed.is_a?(Hash) && parsed.dig("message")&.include?("limit")
        raise RateLimitError, parsed["message"]
      end
    end

    def default_error_transformer(error)
      case error
      when RateLimitError
        error
      when Faraday::TooManyRequestsError
        RateLimitError.new("FMP rate limit exceeded", details: error.response&.dig(:body))
      when Faraday::Error
        self.class::Error.new(error.message, details: error.response&.dig(:body))
      else
        self.class::Error.new(error.message)
      end
    end
end
