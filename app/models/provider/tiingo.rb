class Provider::Tiingo < Provider
  include SecurityConcept, RateLimitable
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Tiingo::Error
  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  # Minimum delay between requests to avoid rate limiting (in seconds)
  MIN_REQUEST_INTERVAL = 1.5

  # Maximum unique symbols per month (Tiingo free tier limit)
  MAX_SYMBOLS_PER_MONTH = 500

  # Maximum requests per hour
  MAX_REQUESTS_PER_HOUR = 1000

  # Tiingo exchange names to MIC codes
  TIINGO_EXCHANGE_TO_MIC = {
    "NASDAQ" => "XNAS",
    "NYSE" => "XNYS",
    "NYSE ARCA" => "XARC",
    "NYSE MKT" => "XASE",
    "BATS" => "BATS",
    "LSE" => "XLON",
    "SHE" => "XSHE",
    "SHG" => "XSHG",
    "OTCMKTS" => "XOTC",
    "OTCD" => "XOTC",
    "PINK" => "XOTC"
  }.freeze

  # Tiingo asset types to normalized kinds
  TIINGO_ASSET_TYPE_MAP = {
    "Stock" => "common stock",
    "ETF" => "etf",
    "Mutual Fund" => "mutual fund"
  }.freeze

  def initialize(api_key)
    @api_key = api_key # pipelock:ignore
  end

  def healthy?
    with_provider_response do
      response = client.get("#{base_url}/tiingo/daily/AAPL")
      parsed = JSON.parse(response.body)
      parsed.dig("ticker").present?
    end
  end

  def usage
    with_provider_response do
      count_key = "tiingo:symbol_count:#{Date.current.strftime('%Y-%m')}"
      symbols_used = Rails.cache.read(count_key).to_i

      UsageData.new(
        used: symbols_used,
        limit: MAX_SYMBOLS_PER_MONTH,
        utilization: (symbols_used.to_f / MAX_SYMBOLS_PER_MONTH * 100).round(1),
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

      response = client.get("#{base_url}/tiingo/utilities/search") do |req|
        req.params["query"] = symbol
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      unless parsed.is_a?(Array)
        raise Error, "Unexpected response format from search endpoint"
      end

      parsed.map do |security|
        ticker = security["ticker"]
        currency = security["priceCurrency"]

        # Cache the API-returned currency so fetch_security_prices can use it
        # without making a second search request
        if currency.present? && ticker.present?
          Rails.cache.write("tiingo:currency:#{ticker.upcase}", currency, expires_in: 24.hours)
        end

        Security.new(
          symbol: ticker,
          name: security["name"],
          logo_url: nil,
          exchange_operating_mic: map_exchange_to_mic(security["exchange"]),
          country_code: security["countryCode"].presence || country_code,
          currency: currency
        )
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      throttle_request
      track_symbol(symbol)

      response = client.get("#{base_url}/tiingo/daily/#{CGI.escape(symbol)}")

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      # The daily metadata endpoint returns exchangeCode (e.g., "NYSE ARCA", "OTCD")
      resolved_mic = exchange_operating_mic.presence || map_exchange_to_mic(parsed["exchangeCode"])

      SecurityInfo.new(
        symbol: parsed["ticker"] || symbol,
        name: parsed["name"],
        links: nil,
        logo_url: nil,
        description: parsed["description"],
        kind: nil,
        exchange_operating_mic: resolved_mic
      )
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      historical_data = fetch_security_prices(symbol:, exchange_operating_mic:, start_date: date, end_date: date)

      raise historical_data.error if historical_data.error.present?
      raise InvalidSecurityPriceError, "No prices found for security #{symbol} on date #{date}" if historical_data.data.blank?

      historical_data.data.first
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      throttle_request
      track_symbol(symbol)

      response = client.get("#{base_url}/tiingo/daily/#{CGI.escape(symbol)}/prices") do |req|
        req.params["startDate"] = start_date.to_s
        req.params["endDate"] = end_date.to_s
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      unless parsed.is_a?(Array)
        error_message = parsed.is_a?(Hash) ? (parsed["detail"] || "Unexpected response format") : "Unexpected response format"
        raise InvalidSecurityPriceError, "API error: #{error_message}"
      end

      # Prefer cached currency from search results to avoid a second API call
      cache_key = "tiingo:currency:#{symbol.upcase}"
      currency = Rails.cache.read(cache_key) || fetch_currency_for_symbol(symbol)

      parsed.map do |resp|
        price = resp["close"]
        date = resp["date"]

        if price.nil? || price.to_f <= 0
          Rails.logger.warn("#{self.class.name} returned invalid price data for security #{symbol} on: #{date}.  Price data: #{price.inspect}")
          next
        end

        Price.new(
          symbol: symbol,
          date: Date.parse(date),
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
      ENV["TIINGO_URL"] || "https://api.tiingo.com"
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
        faraday.headers["Authorization"] = "Token #{api_key}"
        faraday.headers["Content-Type"] = "application/json"
      end
    end

    # Adds hourly request counter on top of the interval throttle from RateLimitable.
    def throttle_request
      super

      # Global per-hour request counter via cache (Redis).
      # Atomic increment-then-check avoids the TOCTOU of read-check-increment.
      hour_key = "tiingo:requests:#{Time.current.to_i / 3600}"
      new_count = Rails.cache.increment(hour_key, 1, expires_in: 7200.seconds).to_i

      if new_count >= max_requests_per_hour
        raise RateLimitError, "Tiingo hourly request limit reached (#{new_count}/#{max_requests_per_hour})"
      end
    end

    # Tracks unique symbols queried per month to stay within Tiingo's 500 symbols/month limit.
    # Uses atomic set-if-absent (Redis SETNX) to eliminate the read-then-write race
    # where two concurrent workers could both see the symbol as untracked and both
    # increment the counter.
    def track_symbol(symbol)
      symbol_key = "tiingo:symbol:#{Date.current.strftime('%Y-%m')}:#{symbol.upcase}"
      count_key  = "tiingo:symbol_count:#{Date.current.strftime('%Y-%m')}"

      # Atomic write-if-absent: returns false when the key already exists (Redis SETNX).
      # Only the first worker to claim this symbol will proceed to increment the counter.
      return unless Rails.cache.write(symbol_key, true, expires_in: 35.days, unless_exist: true)

      new_count = Rails.cache.increment(count_key, 1, expires_in: 35.days).to_i

      if new_count >= MAX_SYMBOLS_PER_MONTH
        Rails.cache.decrement(count_key, 1)
        Rails.cache.delete(symbol_key)
        raise RateLimitError, "Tiingo unique symbol limit reached (#{MAX_SYMBOLS_PER_MONTH} per month)"
      end
    end

    # min_request_interval provided by RateLimitable

    def max_requests_per_hour
      ENV.fetch("TIINGO_MAX_REQUESTS_PER_HOUR", MAX_REQUESTS_PER_HOUR).to_i
    end

    # Fetches the price currency for a symbol via the search endpoint.
    # Only called as a fallback when the cache (populated by search_securities)
    # doesn't have the currency. Raises on failure to avoid silently mislabeling
    # non-USD instruments as USD.
    def fetch_currency_for_symbol(symbol)
      throttle_request

      response = client.get("#{base_url}/tiingo/utilities/search") do |req|
        req.params["query"] = symbol
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      if parsed.is_a?(Array)
        match = parsed.find { |s| s["ticker"]&.upcase == symbol.upcase }
        currency = match&.dig("priceCurrency")

        if currency.present?
          Rails.cache.write("tiingo:currency:#{symbol.upcase}", currency, expires_in: 24.hours)
          return currency
        end
      end

      raise Error, "Could not determine currency for #{symbol} from Tiingo search"
    end

    def map_exchange_to_mic(exchange_name)
      return nil if exchange_name.blank?
      TIINGO_EXCHANGE_TO_MIC[exchange_name.strip] || exchange_name.strip
    end

    def check_api_error!(parsed)
      return unless parsed.is_a?(Hash) && parsed["detail"].present?

      detail = parsed["detail"]

      if detail.downcase.include?("rate limit") || detail.downcase.include?("too many")
        raise RateLimitError, detail
      end

      raise Error, "API error: #{detail}"
    end
end
