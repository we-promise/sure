require "set"

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

  HEALTH_STATUS_FRESHNESS = {
    healthy: 15.minutes,
    rate_limited: 30.minutes,
    unavailable: 5.minutes
  }.freeze
  HEALTH_STATUS_RETENTION = 1.hour
  HEALTH_LOCK_DURATION = 15.seconds
  HEALTH_STATUS_CACHE_KEY = "yahoo_finance_health_status"
  HEALTH_LOCK_CACHE_KEY = "yahoo_finance_health_status_lock"

  INVALID_CRUMBS = Set.new([ "too many requests" ]).freeze

  # Maximum lookback window for historical data (configurable)
  MAX_LOOKBACK_WINDOW = 10.years

  def max_history_days
    (MAX_LOOKBACK_WINDOW / 1.day).to_i
  end

  # Minimum delay between requests to avoid rate limiting (in seconds)
  MIN_REQUEST_INTERVAL = 0.5

  # Pool of modern browser user-agents to rotate through
  # Based on https://github.com/ranaroussi/yfinance/pull/2277
  # UPDATED user-agents string on 2026-02-27 with current versions of browsers (Chrome 145, Firefox 148, Safari 26)
  USER_AGENTS = [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36 Edg/145.0.0.0",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:148.0) Gecko/20100101 Firefox/148.0"
  ].freeze

  def initialize
    # Yahoo Finance doesn't require an API key but we may want to add proxy support later
    @cache_prefix = "yahoo_finance"
  end

  def health_status
    assessment = read_health_cache(HEALTH_STATUS_CACHE_KEY)
    return assessment[:status] if assessment_fresh?(assessment)

    YahooFinanceHealthCheckJob.perform_later
    assessment&.dig(:status) || :unknown
  rescue HealthCacheError => e
    record_health_cache_failure(e)
    :unknown
  end

  def refresh_health_status
    assessment = read_health_cache(HEALTH_STATUS_CACHE_KEY)
    return assessment[:status] if assessment_fresh?(assessment)

    lock_token = SecureRandom.uuid
    lock_acquired = write_health_cache(
      HEALTH_LOCK_CACHE_KEY,
      lock_token,
      expires_in: HEALTH_LOCK_DURATION,
      unless_exist: true
    )
    return assessment&.dig(:status) || :unknown unless lock_acquired
    return :unknown unless health_lock_owned?(lock_token)

    result = perform_health_check
    completed_assessment = result.merge(checked_at: Time.current)
    unless publish_health_assessment(lock_token, completed_assessment)
      return read_health_cache(HEALTH_STATUS_CACHE_KEY)&.dig(:status) || :unknown
    end

    record_health_transition(assessment, result)
    status = result.fetch(:status)
    released = release_health_lock(lock_token)
    lock_token = nil
    released ? status : :unknown
  rescue HealthCacheError => e
    record_health_cache_failure(e)
    :unknown
  ensure
    release_health_lock(lock_token) if lock_token.present?
  end

  def healthy?
    health_status == :healthy
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
          mic = map_exchange_mic(quote["exchange"])

          Security.new(
            symbol: quote["symbol"],
            name: quote["longname"] || quote["shortname"] || quote["symbol"],
            logo_url: nil, # Yahoo search doesn't provide logos
            exchange_operating_mic: mic,
            country_code: ::Security::EXCHANGES.dig(mic, "country") || map_country_code(quote["exchDisp"])
          )
        end

        securities = deduplicate_dual_listings(securities) unless exchange_operating_mic.present?

        cache_result(cache_key, securities)
        securities
      end
    rescue JSON::ParserError => e
      raise Error, "Invalid search response format: #{e.message}"
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      symbol = normalize_symbol(symbol, exchange_operating_mic)

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
        if data.dig("quoteSummary", "error", "code") == "Unauthorized"
          raise AuthenticationError, "Yahoo Finance authentication failed after crumb refresh"
        end
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
      symbol = normalize_symbol(symbol, exchange_operating_mic)
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
      symbol = normalize_symbol(symbol, exchange_operating_mic)
      validate_date_params!(start_date, end_date)
      # Convert dates to Unix timestamps using UTC to ensure consistent epoch boundaries across timezones
      period1 = start_date.to_time.utc.to_i
      period2 = end_date.end_of_day.to_time.utc.to_i

      throttle_request
      data = fetch_authenticated_chart(symbol, {
        "period1" => period1,
        "period2" => period2,
        "interval" => "1d",
        "includeAdjustedClose" => true
      })

      chart_data = data.dig("chart", "result", 0)

      raise Error, "No chart data found for #{symbol}" unless chart_data

      timestamps = chart_data.dig("timestamp") || []
      quotes = chart_data.dig("indicators", "quote", 0) || {}
      closes = quotes["close"] || []

      # Get currency from metadata
      meta_exchange = chart_data.dig("meta", "exchangeName") || ""
      raw_currency = chart_data.dig("meta", "currency")
      raw_currency ||= default_currency_for_exchange(meta_exchange) || "USD"

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

    HealthCacheError = Class.new(StandardError)

    def perform_health_check
      stage = :cookie

      cookie, crumb, stage = fetch_health_cookie_and_crumb

      stage = :chart
      chart_response = health_authenticated_client(cookie).get("#{base_url}/v8/finance/chart/AAPL") do |req|
        req.params["interval"] = "1d"
        req.params["range"] = "1d"
        req.params["crumb"] = crumb
      end
      return health_result(:rate_limited, stage:, http_status: 429) if chart_response.status == 429
      return health_result(:unavailable, stage:, http_status: chart_response.status) unless chart_response.success?

      data = JSON.parse(chart_response.body)
      if data.dig("chart", "error", "code") == "Unauthorized"
        delete_health_cache("#{@cache_prefix}_auth_crumb")
        return health_result(:unavailable, stage:, http_status: chart_response.status)
      end
      return health_result(:unavailable, stage:, http_status: chart_response.status) if data.dig("chart", "error").present?

      results = data.dig("chart", "result")
      health_result(results.present? ? :healthy : :unavailable, stage:, http_status: chart_response.status)
    rescue HealthCacheError
      raise
    rescue Faraday::Error, JSON::ParserError => e
      health_result(:unavailable, stage:, exception_class: e.class.name, http_status: faraday_status(e))
    rescue RateLimitError => e
      health_result(:rate_limited, stage: :crumb, exception_class: e.class.name, http_status: e.details&.dig(:status))
    rescue AuthenticationError => e
      health_result(:unavailable, stage:, exception_class: e.class.name, http_status: e.details&.dig(:status))
    rescue => e
      health_result(:unavailable, stage:, exception_class: e.class.name)
    end

    def health_result(status, stage:, exception_class: nil, http_status: nil)
      {
        status: status,
        stage: stage,
        exception_class: exception_class,
        http_status: http_status
      }.compact
    end

    def fetch_health_cookie_and_crumb
      cache_key = "#{@cache_prefix}_auth_crumb"
      cached = read_health_cache(cache_key)
      if cached.present?
        return [ cached.first, cached.second, :authentication_cache ] if valid_crumb?(cached.second)

        delete_health_cache(cache_key)
      end

      cookie, crumb, cache_duration = request_cookie_and_crumb(health_auth_client)
      write_health_cache!(cache_key, [ cookie, crumb ], expires_in: cache_duration)
      [ cookie, crumb, :crumb ]
    end

    def faraday_status(error)
      error.response&.dig(:status) if error.respond_to?(:response)
    end

    def health_auth_client
      @health_auth_client ||= Faraday.new(ssl: self.class.faraday_ssl_options) do |faraday|
        configure_health_client(faraday)
        faraday.headers["Accept"] = "*/*"
      end
    end

    def health_authenticated_client(cookie)
      Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        configure_health_client(faraday)
        faraday.request :json
        faraday.headers["Accept"] = "application/json"
        faraday.headers["Cookie"] = cookie
      end
    end

    def configure_health_client(faraday)
      faraday.headers["User-Agent"] = random_user_agent
      faraday.headers["Accept-Language"] = "en-US,en;q=0.9"
      faraday.headers["Cache-Control"] = "no-cache"
      faraday.headers["Pragma"] = "no-cache"
      faraday.options.timeout = 5
      faraday.options.open_timeout = 3
    end

    def read_health_cache(key)
      Rails.cache.read(key)
    rescue => e
      raise HealthCacheError, e.class.name
    end

    def write_health_cache(key, value, **options)
      Rails.cache.write(key, value, **options)
    rescue => e
      raise HealthCacheError, e.class.name
    end

    def write_health_cache!(key, value, **options)
      return true if write_health_cache(key, value, **options)

      raise HealthCacheError, "CacheWriteFailed"
    end

    def delete_health_cache(key)
      Rails.cache.delete(key)
    rescue => e
      raise HealthCacheError, e.class.name
    end

    def publish_health_assessment(lock_token, assessment)
      return false unless health_lock_owned?(lock_token)

      write_health_cache!(HEALTH_STATUS_CACHE_KEY, assessment, expires_in: HEALTH_STATUS_RETENTION)
      return true if health_lock_owned?(lock_token)

      delete_health_cache(HEALTH_STATUS_CACHE_KEY) if read_health_cache(HEALTH_STATUS_CACHE_KEY) == assessment
      false
    end

    def release_health_lock(lock_token)
      return true unless health_lock_owned?(lock_token)

      Rails.cache.delete(HEALTH_LOCK_CACHE_KEY)
      true
    rescue HealthCacheError => e
      record_health_cache_failure(e)
      false
    rescue => e
      record_health_cache_failure(HealthCacheError.new(e.class.name))
      false
    end

    def health_lock_owned?(lock_token)
      read_health_cache(HEALTH_LOCK_CACHE_KEY) == lock_token
    end

    def record_health_transition(previous_assessment, result)
      previous_status = previous_assessment&.dig(:status)
      return if previous_status == result[:status]

      status = result.fetch(:status)
      DebugLogEntry.capture(
        category: "provider_health",
        level: status == :healthy ? "info" : "warn",
        message: "Yahoo Finance Provider Health Status changed to #{status}",
        source: self.class.name,
        provider_key: "yahoo_finance",
        metadata: {
          previous_state: previous_status || :unknown,
          new_state: status,
          health_check_stage: result[:stage],
          exception_class: result[:exception_class],
          http_status: result[:http_status]
        }.compact
      )
    end

    def record_health_cache_failure(error)
      DebugLogEntry.capture(
        category: "provider_health_cache",
        level: "warn",
        message: "Yahoo Finance Provider Health Status cache is unavailable",
        source: self.class.name,
        provider_key: "yahoo_finance",
        metadata: { exception_class: error.message }
      )
    end

    def assessment_fresh?(assessment)
      return false unless assessment

      freshness = HEALTH_STATUS_FRESHNESS[assessment[:status]]
      freshness && assessment[:checked_at] >= freshness.ago
    end

    def base_url
      ENV["YAHOO_FINANCE_URL"] || "https://query1.finance.yahoo.com"
    end

    # ================================
    #      Currency Normalization
    # ================================

    # Per-exchange configuration for Yahoo Finance.  Each entry maps an ISO
    # MIC code to its Yahoo-specific symbol suffix, the default currency when
    # Yahoo omits one, and an optional dual-listing group with a preference
    # rank (lower = preferred).  Adding a new market is a one-line hash entry.
    EXCHANGE_CONFIG = {
      "XNSE" => { yahoo_suffix: ".NS", default_currency: "INR", dual_list_group: :india, preference_rank: 0 },
      "XBOM" => { yahoo_suffix: ".BO", default_currency: "INR", dual_list_group: :india, preference_rank: 1 },
      "XBOG" => { yahoo_suffix: ".CL", default_currency: "COP" }
    }.freeze

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

    # Appends the Yahoo Finance symbol suffix for exchanges that require one
    # (e.g. XNSE → ".NS", XBOM → ".BO").  Already-suffixed symbols pass through.
    def normalize_symbol(symbol, exchange_operating_mic)
      suffix = EXCHANGE_CONFIG.dig(exchange_operating_mic, :yahoo_suffix)
      return symbol if suffix.nil? || symbol.end_with?(suffix)
      "#{symbol}#{suffix}"
    end

    # Returns the default currency for a Yahoo exchange name (e.g. "NSE" → "INR")
    # by resolving through map_exchange_mic → EXCHANGE_CONFIG.  Returns nil for
    # unknown exchanges so callers can fall back to their own default.
    def default_currency_for_exchange(yahoo_exchange_name)
      mic = map_exchange_mic(yahoo_exchange_name)
      EXCHANGE_CONFIG.dig(mic, :default_currency)
    end

    # De-duplicates dual-listed securities that share the same company name
    # and dual_list_group (e.g. NSE + BSE for India), keeping the exchange
    # with the lowest preference_rank.  Preserves Yahoo's original relevance
    # ordering by removing duplicates in-place rather than reordering.
    def deduplicate_dual_listings(securities)
      dominated = Set.new

      securities
        .select { |s| EXCHANGE_CONFIG.dig(s.exchange_operating_mic, :dual_list_group) }
        .group_by { |s| [ EXCHANGE_CONFIG[s.exchange_operating_mic][:dual_list_group], s.name.to_s.strip.downcase ] }
        .each_value do |group|
          next unless group.size > 1
          preferred = group.min_by { |s| EXCHANGE_CONFIG[s.exchange_operating_mic][:preference_rank] }
          group.each { |s| dominated << s.object_id unless s.equal?(preferred) }
        end

      return securities if dominated.empty?
      securities.reject { |s| dominated.include?(s.object_id) }
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
          rate: (BigDecimal("1") / BigDecimal(close_rate.to_s)).round(12)
        )
      end

      rates
    end

    # Makes a single authenticated GET to /v8/finance/chart/:symbol.
    # If Yahoo returns a stale-crumb error (200 OK with Unauthorized body),
    # clears the crumb cache and retries once with fresh credentials.
    def fetch_authenticated_chart(symbol, params)
      cookie, crumb = fetch_cookie_and_crumb
      response = authenticated_client(cookie).get("#{base_url}/v8/finance/chart/#{symbol}") do |req|
        params.each { |k, v| req.params[k] = v }
        req.params["crumb"] = crumb
      end
      data = JSON.parse(response.body)

      if data.dig("chart", "error", "code") == "Unauthorized"
        clear_crumb_cache
        cookie, crumb = fetch_cookie_and_crumb
        response = authenticated_client(cookie).get("#{base_url}/v8/finance/chart/#{symbol}") do |req|
          params.each { |k, v| req.params[k] = v }
          req.params["crumb"] = crumb
        end
        data = JSON.parse(response.body)
        if data.dig("chart", "error", "code") == "Unauthorized"
          raise AuthenticationError, "Yahoo Finance authentication failed after crumb refresh"
        end
      end

      data
    end

    def fetch_chart_data(symbol, start_date, end_date, &block)
      period1 = start_date.to_time.utc.to_i
      period2 = end_date.end_of_day.to_time.utc.to_i

      begin
        throttle_request
        data = fetch_authenticated_chart(symbol, {
          "period1" => period1,
          "period2" => period2,
          "interval" => "1d",
          "includeAdjustedClose" => true
        })

        # Check for Yahoo Finance errors
        if data.dig("chart", "error")
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
      rescue Faraday::Error, JSON::ParserError => e
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
      if cached.present?
        return cached if valid_crumb?(cached.second)

        Rails.cache.delete(cache_key)
      end

      cookie, crumb, cache_duration = request_cookie_and_crumb(auth_client)
      result = [ cookie, crumb ]
      Rails.cache.write(cache_key, result, expires_in: cache_duration)
      result
    rescue Faraday::TooManyRequestsError => e
      raise RateLimitError.new(
        "Yahoo Finance rate limit exceeded",
        details: { status: e.response&.dig(:status) }
      )
    rescue Faraday::Error => e
      raise AuthenticationError, "Failed to authenticate with Yahoo Finance: #{e.message}"
    end

    def request_cookie_and_crumb(authentication_client)
      cookie_response = authentication_client.get("https://fc.yahoo.com")
      if cookie_response.respond_to?(:status) && cookie_response.status == 429
        raise RateLimitError.new(
          "Yahoo Finance rate limit exceeded",
          details: { status: cookie_response.status }
        )
      end

      cookie = extract_cookie(cookie_response)
      cookie_max_age = extract_cookie_max_age(cookie_response)
      raise AuthenticationError, "Failed to obtain Yahoo Finance cookie" if cookie.blank?

      crumb_response = authentication_client.get("#{base_url}/v1/test/getcrumb") do |req|
        req.headers["Cookie"] = cookie
      end
      if crumb_response.status == 429
        raise RateLimitError.new(
          "Yahoo Finance rate limit exceeded",
          details: { status: crumb_response.status }
        )
      end
      unless crumb_response.success?
        raise AuthenticationError.new(
          "Failed to obtain Yahoo Finance crumb",
          details: { status: crumb_response.status }
        )
      end

      crumb = crumb_response.body.to_s.strip
      unless valid_crumb?(crumb)
        error_class = INVALID_CRUMBS.include?(crumb.downcase) ? RateLimitError : AuthenticationError
        raise error_class.new(
          "Failed to obtain Yahoo Finance crumb",
          details: { status: crumb_response.status }
        )
      end

      cache_duration = [ cookie_max_age || MAX_CRUMB_CACHE_DURATION, MAX_CRUMB_CACHE_DURATION ].min
      [ cookie, crumb, cache_duration ]
    end

    def valid_crumb?(crumb)
      crumb.present? && !INVALID_CRUMBS.include?(crumb.to_s.strip.downcase)
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
      when "NSE", "NSI"
        "XNSE" # National Stock Exchange of India
      when "BSE", "BOM"
        "XBOM" # BSE (Bombay Stock Exchange)
      when "BVC"
        "XBOG" # Colombian Securities Exchange
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
