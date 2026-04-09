class Provider::TwelveData < Provider
  include ExchangeRateConcept, SecurityConcept
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::TwelveData::Error
  Error = Class.new(Provider::Error)
  InvalidExchangeRateError = Class.new(Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  # Minimum delay between requests to avoid rate limiting (in seconds)
  MIN_REQUEST_INTERVAL = 1.0

  # Pattern to detect plan upgrade errors in API responses
  PLAN_UPGRADE_PATTERN = /available starting with (\w+)/i

  # Returns true if the error message indicates a plan upgrade is required
  def self.plan_upgrade_required?(error_message)
    return false if error_message.blank?
    PLAN_UPGRADE_PATTERN.match?(error_message)
  end

  # Extracts the required plan name from an error message, or nil if not found
  def self.extract_required_plan(error_message)
    return nil if error_message.blank?
    match = error_message.match(PLAN_UPGRADE_PATTERN)
    match ? match[1] : nil
  end

  def initialize(api_key)
    @api_key = api_key
  end

  def healthy?
    with_provider_response do
      response = client.get("#{base_url}/api_usage")
      JSON.parse(response.body).dig("plan_category").present?
    end
  end

  def usage
    with_provider_response do
      response = client.get("#{base_url}/api_usage")

      parsed = JSON.parse(response.body)

      limit = parsed.dig("plan_daily_limit")
      used = parsed.dig("daily_usage")
      remaining = limit - used

      UsageData.new(
        used: used,
        limit: limit,
        utilization: used / limit * 100,
        plan: parsed.dig("plan_category"),
      )
    end
  end

  # ================================
  #          Exchange Rates
  # ================================

  def fetch_exchange_rate(from:, to:, date:)
    with_provider_response do
      throttle_request
      response = client.get("#{base_url}/exchange_rate") do |req|
        req.params["symbol"] = "#{from}/#{to}"
        req.params["date"] = date.to_s
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      Rate.new(date: date.to_date, from:, to:, rate: parsed.dig("rate"))
    end
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    with_provider_response do
      # Try to fetch the currency pair via the time_series API (consumes 1 credit) - this might not return anything as the API does not provide time series data for all possible currency pairs
      throttle_request
      response = client.get("#{base_url}/time_series") do |req|
        req.params["symbol"] = "#{from}/#{to}"
        req.params["start_date"] = start_date.to_s
        req.params["end_date"] = end_date.to_s
        req.params["interval"] = "1day"
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)
      data = parsed.dig("values")

      # If currency pair is not available, try to fetch via the time_series/cross API (consumes 5 credits)
      if data.nil?
        Rails.logger.info("#{self.class.name}: Currency pair #{from}/#{to} not available, fetching via time_series/cross API")
        throttle_request(credits: 5)
        response = client.get("#{base_url}/time_series/cross") do |req|
          req.params["base"] = from
          req.params["quote"] = to
          req.params["start_date"] = start_date.to_s
          req.params["end_date"] = end_date.to_s
          req.params["interval"] = "1day"
        end

        parsed = JSON.parse(response.body)
        check_api_error!(parsed)
        data = parsed.dig("values")
      end

      if data.nil?
        error_message = parsed.dig("message") || "No data returned"
        error_code = parsed.dig("code") || "unknown"
        raise InvalidExchangeRateError, "API error (code: #{error_code}): #{error_message}"
      end

      data.map do |resp|
        rate = resp.dig("close")
        date = resp.dig("datetime")
        if rate.nil? || rate.to_f <= 0
          Rails.logger.warn("#{self.class.name} returned invalid rate data for pair from: #{from} to: #{to} on: #{date}.  Rate data: #{rate.inspect}")
          next
        end

        Rate.new(date: date.to_date, from:, to:, rate:)
      end.compact
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      throttle_request
      response = client.get("#{base_url}/symbol_search") do |req|
        req.params["symbol"] = symbol
        req.params["outputsize"] = 25
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)
      data = parsed.dig("data")

      if data.nil?
        error_message = parsed.dig("message") || "No data returned"
        error_code = parsed.dig("code") || "unknown"
        raise Error, "API error (code: #{error_code}): #{error_message}"
      end

      data.map do |security|
        country = ISO3166::Country.find_country_by_any_name(security.dig("country"))

        Security.new(
          symbol: security.dig("symbol"),
          name: security.dig("instrument_name"),
          logo_url: nil,
          exchange_operating_mic: security.dig("mic_code"),
          country_code: country ? country.alpha2 : nil,
          currency: security.dig("currency")
        )
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      throttle_request
      response = client.get("#{base_url}/profile") do |req|
        req.params["symbol"] = symbol
        req.params["mic_code"] = exchange_operating_mic
      end

      profile = JSON.parse(response.body)
      check_api_error!(profile)

      throttle_request
      response = client.get("#{base_url}/logo") do |req|
        req.params["symbol"] = symbol
        req.params["mic_code"] = exchange_operating_mic
      end

      logo = JSON.parse(response.body)
      check_api_error!(logo)

      SecurityInfo.new(
        symbol: symbol,
        name: profile.dig("name"),
        links: profile.dig("website"),
        logo_url: logo.dig("url"),
        description: profile.dig("description"),
        kind: profile.dig("type"),
        exchange_operating_mic: exchange_operating_mic
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
      response = client.get("#{base_url}/time_series") do |req|
        req.params["symbol"] = symbol
        req.params["mic_code"] = exchange_operating_mic
        req.params["start_date"] = start_date.to_s
        req.params["end_date"] = end_date.to_s
        req.params["interval"] = "1day"
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)
      values = parsed.dig("values")

      if values.nil?
        error_message = parsed.dig("message") || "No data returned"
        error_code = parsed.dig("code") || "unknown"
        raise InvalidSecurityPriceError, "API error (code: #{error_code}): #{error_message}"
      end

      values.map do |resp|
        price = resp.dig("close")
        date = resp.dig("datetime")
        if price.nil? || price.to_f <= 0
          Rails.logger.warn("#{self.class.name} returned invalid price data for security #{symbol} on: #{date}.  Price data: #{price.inspect}")
          next
        end

        Price.new(
          symbol: symbol,
          date: date.to_date,
          price: price,
          currency: parsed.dig("meta", "currency") || parsed.dig("currency"),
          exchange_operating_mic: exchange_operating_mic
        )
      end.compact
    end
  end

  private
    attr_reader :api_key

    def base_url
      ENV["TWELVE_DATA_URL"] || "https://api.twelvedata.com"
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
        faraday.headers["Authorization"] = "apikey #{api_key}"
      end
    end

    # Paces API requests to stay within TwelveData's rate limits. Sleeps inline
    # because the API physically cannot be called faster — this is unavoidable
    # with a rate-limited provider. The 5-minute cache lock TTL in
    # ExchangeRate::Provided accounts for worst-case throttle waits.
    def throttle_request(credits: 1)
      # Layer 1: Per-instance minimum interval between calls
      @last_request_time ||= Time.at(0)
      elapsed = Time.current - @last_request_time
      sleep_time = min_request_interval - elapsed
      sleep(sleep_time) if sleep_time > 0

      # Layer 2: Global per-minute credit counter via cache (Redis in prod).
      # Read current usage first — if adding these credits would exceed the limit,
      # wait for the next minute BEFORE incrementing. This ensures credits are
      # charged to the minute the request actually fires in, not a stale minute
      # we slept through (which would undercount the new minute's usage).
      minute_key = "twelve_data:credits:#{Time.current.to_i / 60}"
      current_count = Rails.cache.read(minute_key).to_i

      if current_count + credits > max_requests_per_minute
        wait_seconds = 60 - (Time.current.to_i % 60) + 1
        Rails.logger.info("TwelveData: #{current_count + credits}/#{max_requests_per_minute} credits this minute, waiting #{wait_seconds}s")
        sleep(wait_seconds)
      end

      # Charge credits to the minute the request actually fires in
      active_minute_key = "twelve_data:credits:#{Time.current.to_i / 60}"
      Rails.cache.increment(active_minute_key, credits, expires_in: 120.seconds)

      # Set timestamp after all waits so the next call's 1s pacing is measured
      # from when this request actually fires, not from before the minute wait.
      @last_request_time = Time.current
    end

    def min_request_interval
      ENV.fetch("TWELVE_DATA_MIN_REQUEST_INTERVAL", MIN_REQUEST_INTERVAL).to_f
    end

    def max_requests_per_minute
      ENV.fetch("TWELVE_DATA_MAX_REQUESTS_PER_MINUTE", 7).to_i
    end

    def check_api_error!(parsed)
      return unless parsed.is_a?(Hash) && parsed["code"].present?

      if parsed["code"] == 429
        raise RateLimitError, parsed["message"] || "Rate limit exceeded"
      end

      raise Error, "API error (code: #{parsed["code"]}): #{parsed["message"] || "Unknown error"}"
    end

    def default_error_transformer(error)
      case error
      when RateLimitError
        error
      when Faraday::TooManyRequestsError
        RateLimitError.new("TwelveData rate limit exceeded", details: error.response&.dig(:body))
      when Faraday::Error
        self.class::Error.new(error.message, details: error.response&.dig(:body))
      else
        self.class::Error.new(error.message)
      end
    end
end
