class Provider::TwelveData < Provider
  include ExchangeRateConcept, SecurityConcept
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::TwelveData::Error
  Error = Class.new(Provider::Error)
  InvalidExchangeRateError = Class.new(Error)
  InvalidSecurityPriceError = Class.new(Error)

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
      parsed = get_with_rate_limit_retry("#{base_url}/api_usage")
      parsed.dig("plan_category").present?
    end
  end

  def usage
    with_provider_response do
      parsed = get_with_rate_limit_retry("#{base_url}/api_usage")

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
      parsed = get_with_rate_limit_retry("#{base_url}/exchange_rate") do |req|
        req.params["symbol"] = "#{from}/#{to}"
        req.params["date"] = date.to_s
      end

      Rate.new(date: date.to_date, from:, to:, rate: parsed.dig("rate"))
    end
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    with_provider_response do
      # Try to fetch the currency pair via the time_series API (consumes 1 credit) - this might not return anything as the API does not provide time series data for all possible currency pairs
      parsed = get_with_rate_limit_retry("#{base_url}/time_series") do |req|
        req.params["symbol"] = "#{from}/#{to}"
        req.params["start_date"] = start_date.to_s
        req.params["end_date"] = end_date.to_s
        req.params["interval"] = "1day"
      end

      data = parsed.dig("values")

      # If currency pair is not available, try to fetch via the time_series/cross API (consumes 5 credits)
      if data.nil? && parsed.dig("code") != RATE_LIMIT_CODE
        Rails.logger.info("#{self.class.name}: Currency pair #{from}/#{to} not available, fetching via time_series/cross API")
        parsed = get_with_rate_limit_retry("#{base_url}/time_series/cross") do |req|
          req.params["base"] = from
          req.params["quote"] = to
          req.params["start_date"] = start_date.to_s
          req.params["end_date"] = end_date.to_s
          req.params["interval"] = "1day"
        end

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
      parsed = get_with_rate_limit_retry("#{base_url}/symbol_search") do |req|
        req.params["symbol"] = symbol
        req.params["outputsize"] = 25
      end

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
          country_code: country ? country.alpha2 : nil
        )
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      profile = get_with_rate_limit_retry("#{base_url}/profile") do |req|
        req.params["symbol"] = symbol
        req.params["mic_code"] = exchange_operating_mic
      end

      logo = get_with_rate_limit_retry("#{base_url}/logo") do |req|
        req.params["symbol"] = symbol
        req.params["mic_code"] = exchange_operating_mic
      end

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

      raise ProviderError, "No prices found for security #{symbol} on date #{date}" if historical_data.data.empty?

      historical_data.data.first
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      parsed = get_with_rate_limit_retry("#{base_url}/time_series") do |req|
        req.params["symbol"] = symbol
        req.params["mic_code"] = exchange_operating_mic
        req.params["start_date"] = start_date.to_s
        req.params["end_date"] = end_date.to_s
        req.params["interval"] = "1day"
      end

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
    RATE_LIMIT_CODE = 429
    RATE_LIMIT_WAIT = 60 # seconds — Twelve Data resets credits each minute
    RATE_LIMIT_MAX_RETRIES = 3

    attr_reader :api_key

    # Makes a GET request and automatically retries on Twelve Data rate limit (code 429).
    # Twelve Data returns HTTP 200 with {"code": 429, ...} in the JSON body when rate limited.
    def get_with_rate_limit_retry(url, &block)
      retries = 0

      loop do
        response = client.get(url, &block)
        parsed = JSON.parse(response.body)

        if parsed.dig("code") == RATE_LIMIT_CODE && retries < RATE_LIMIT_MAX_RETRIES
          retries += 1
          Rails.logger.info("#{self.class.name} rate limited, waiting #{RATE_LIMIT_WAIT}s before retry #{retries}/#{RATE_LIMIT_MAX_RETRIES}")
          # NOTE: Blocks the current thread for up to 60s per retry (3 retries max = 180s).
          # Acceptable for single-user self-hosted. For multi-tenant production, consider
          # requeuing the job with a delay instead.
          sleep(RATE_LIMIT_WAIT)
          next
        end

        return parsed
      end
    end

    def base_url
      ENV["TWELVE_DATA_URL"] || "https://api.twelvedata.com"
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.request(:retry, {
          max: 2,
          interval: 0.05,
          interval_randomness: 0.5,
          backoff_factor: 2
        })

        faraday.request :json
        faraday.response :raise_error
        faraday.headers["Authorization"] = "apikey #{api_key}"
      end
    end
end
