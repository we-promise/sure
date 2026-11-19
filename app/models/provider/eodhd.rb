class Provider::Eodhd < Provider
  include SecurityConcept, RateLimitable
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Eodhd::Error
  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  # Minimum delay between requests to avoid rate limiting (in seconds)
  MIN_REQUEST_INTERVAL = 0.5

  # Maximum API calls per day (EODHD free/basic plans are very restrictive)
  MAX_REQUESTS_PER_DAY = 20

  # EODHD bills each fundamentals request as 10 API calls against the daily allowance
  FUNDAMENTALS_REQUEST_COST = 10

  # A fundamentals response is large and slow to start, so it gets a 60 s read
  # limit rather than the client's 20 s: each retry after a timeout bills
  # another ten calls.
  FUNDAMENTALS_READ_TIMEOUT = 60

  # The free tier provides ~1 year of EOD data; paid plans go back 30+ years.
  # Raising EODHD_MAX_REQUESTS_PER_DAY above the free cap signals a paid key.
  def max_history_days
    365 if max_requests_per_day <= MAX_REQUESTS_PER_DAY
  end

  # EODHD uses {SYMBOL}.{EXCHANGE} ticker format with its own exchange codes
  MIC_TO_EODHD_EXCHANGE = {
    "XNYS" => "US", "XNAS" => "US", "XASE" => "US",
    # Other US venues (NASDAQ segments, NYSE Arca, Cboe, IEX, MEMX, regionals, OTC tiers)
    # also trade under EODHD's composite US code
    "ARCX" => "US", "BATS" => "US", "OTCM" => "US", "XNGS" => "US", "XNMS" => "US", "XNCM" => "US", "XARC" => "US",
    "XOTC" => "US", "PINX" => "US", "OTCQ" => "US", "OTCB" => "US", "PSGM" => "US", "XCHI" => "US", "XCIS" => "US",
    "EDGX" => "US", "IEXG" => "US", "MEMX" => "US",
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
    "XNSE" => "NSE",
    "XWAR" => "WAR",
    # Further European venues, using the MICs from EODHD's own exchange list
    # (https://eodhd.com/list-of-stock-markets)
    "XFRA" => "F", "XBRU" => "BR", "XLIS" => "LS", "XWBO" => "VI", "XDUB" => "IR",
    # German regional exchanges
    "XBER" => "BE", "XDUS" => "DU", "XHAM" => "HM", "XHAN" => "HA", "XMUN" => "MU", "XSTU" => "STU",
    # Still accept legacy rows / inputs that store the raw EODHD code as MIC.
    # Persistence always canonicalizes WAR → XWAR via Security::MIC_ALIASES.
    "WAR" => "WAR",
    "F" => "F", "BR" => "BR", "LS" => "LS", "VI" => "VI", "IR" => "IR",
    "BE" => "BE", "DU" => "DU", "HM" => "HM", "HA" => "HA", "MU" => "MU", "STU" => "STU",
    "EUFUND" => "EUFUND"
  }.freeze

  EODHD_EXCHANGE_TO_MIC = {
    "US" => "XNYS", "LSE" => "XLON", "XETRA" => "XETR",
    "TO" => "XTSE", "PA" => "XPAR", "AS" => "XAMS",
    "SW" => "XSWX", "HK" => "XHKG", "AU" => "XASX",
    "TSE" => "XTKS", "MI" => "XMIL", "MC" => "XMAD",
    "OL" => "XOSL", "HE" => "XHEL", "CO" => "XCSE",
    "ST" => "XSTO", "KS" => "XKRX", "BSE" => "XBOM",
    "NSE" => "XNSE", "WAR" => "XWAR",
    "F" => "XFRA", "BR" => "XBRU", "LS" => "XLIS", "VI" => "XWBO", "IR" => "XDUB",
    "BE" => "XBER", "DU" => "XDUS", "HM" => "XHAM", "HA" => "XHAN", "MU" => "XMUN", "STU" => "XSTU"
  }.freeze

  EODHD_COUNTRY_TO_CODE = {
    "USA" => "US", "UK" => "GB", "Germany" => "DE", "France" => "FR",
    "Netherlands" => "NL", "Switzerland" => "CH", "Canada" => "CA",
    "Japan" => "JP", "Australia" => "AU", "Hong Kong" => "HK",
    "Italy" => "IT", "Spain" => "ES", "Norway" => "NO",
    "Finland" => "FI", "Denmark" => "DK", "Sweden" => "SE",
    "South Korea" => "KR", "India" => "IN", "Poland" => "PL"
  }.freeze

  EXCHANGE_CURRENCY = {
    "US" => "USD", "LSE" => "GBP", "XETRA" => "EUR", "TO" => "CAD",
    "PA" => "EUR", "AS" => "EUR", "SW" => "CHF", "HK" => "HKD",
    "AU" => "AUD", "TSE" => "JPY", "MI" => "EUR", "MC" => "EUR",
    "OL" => "NOK", "HE" => "EUR", "CO" => "DKK",
    "ST" => "SEK", "KS" => "KRW", "BSE" => "INR",
    "NSE" => "INR",
    "WAR" => "PLN",
    "F" => "EUR", "BR" => "EUR", "LS" => "EUR", "VI" => "EUR", "IR" => "EUR",
    "BE" => "EUR", "DU" => "EUR", "HM" => "EUR", "HA" => "EUR", "MU" => "EUR", "STU" => "EUR",
    "EUFUND" => "EUR"
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
      used = Rails.cache.read(daily_key, raw: true).to_i

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
      response = client.get("#{base_url}/api/search/#{CGI.escape(symbol)}") do |req|
        req.params["api_token"] = api_key
        req.params["fmt"] = "json"
      end

      parsed = JSON.parse(response.body)
      check_api_error!(parsed)

      unless parsed.is_a?(Array)
        raise Error, "Unexpected response format from search API"
      end

      parsed.first(25).map do |security|
        eodhd_exchange = security.dig("Exchange")
        mic = EODHD_EXCHANGE_TO_MIC[eodhd_exchange] || eodhd_exchange
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
          currency: currency,
          isin: security.dig("ISIN").presence&.to_s&.strip&.upcase
        )
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      ticker = eodhd_symbol(symbol, exchange_operating_mic)
      # Fundamentals cost 10 API calls and fail on plans without them, so don't
      # retry a permanently failed lookup (no plan access, unknown ticker) on every sync.
      failed_key = "eodhd:fundamentals_failed:#{Digest::SHA256.hexdigest(api_key.to_s)[0, 8]}:#{ticker}"
      raise Error, "Fundamentals for #{ticker} failed recently; retrying later" if Rails.cache.read(failed_key)

      # Fundamentals are billed at 10 API calls, so each attempt — including
      # retries — must reserve that cost. The hook registered on the client
      # routes every attempt through this before it reaches EODHD.
      @request_cost = FUNDAMENTALS_REQUEST_COST

      begin
        @last_counted_on = nil

        response = client.get("#{base_url}/api/fundamentals/#{CGI.escape(ticker)}") do |req|
          req.options.timeout = FUNDAMENTALS_READ_TIMEOUT
          req.params["api_token"] = api_key
          req.params["fmt"] = "json"
        end

        parsed = JSON.parse(response.body)
        check_api_error!(parsed)
      rescue RateLimitError
        # Our own quota refusal says nothing about the ticker, so it must not
        # be remembered as a fundamentals failure.
        raise
      rescue Faraday::ForbiddenError, Faraday::ResourceNotFound, Error => e
        Rails.cache.write(failed_key, true, expires_in: 7.days)
        # EODHD documents that a lookup for an unknown ticker (404) is billed at its
        # full price, but not whether a request the plan does not include (403, e.g.
        # fundamentals on the free plan) is. Count it as one request rather than ten:
        # under-counting a refused call is safer than refusing the day's prices.
        # An error in a 200 answer (Error, from check_api_error!) was served, and
        # EODHD bills failed lookups, so it keeps its full price.
        refund_daily_requests(FUNDAMENTALS_REQUEST_COST - 1, key: last_counted_on) if e.is_a?(Faraday::ForbiddenError)
        raise
      rescue Faraday::ClientError => e
        # EODHD answers 402 when the day's calls are used up and does not bill it
        refund_daily_requests(FUNDAMENTALS_REQUEST_COST, key: last_counted_on) if e.response_status == 402
        raise
      ensure
        reset_request_cost!
      end

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

      raise historical_data.error if historical_data.error.present?
      raise InvalidSecurityPriceError, "No prices found for security #{symbol} on date #{date}" if historical_data.data.blank?

      historical_data.data.first
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      ticker = eodhd_symbol(symbol, exchange_operating_mic)

      response = client.get("#{base_url}/api/eod/#{CGI.escape(ticker)}") do |req|
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

      # Prefer the per-security currency cached from search (handles USD LSE
      # listings, etc.), then fall back to the exchange default map — including
      # legacy rows that still store the raw EODHD code as MIC (e.g. "WAR").
      currency = currency_for(exchange_operating_mic: exchange_operating_mic, symbol: symbol)

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
        faraday.options.open_timeout = 5
        faraday.options.timeout      = 20

        faraday.request(:retry, {
          max: 3,
          interval: 1.0,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        })
        # After the retry middleware, so every attempt — not only the first —
        # is throttled and reserved against the daily request budget. The URL
        # decides the billing cost: fundamentals are billed at ten API calls.
        faraday.use RateLimitable::BeforeEachAttempt, ->(env) { count_request_attempt!(env.url) }

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

    def currency_for(exchange_operating_mic:, symbol:)
      # Accept legacy raw EODHD codes (e.g. WAR) and ISO MICs (XWAR).
      # Use ::Security — bare Security here is Provider::SecurityConcept::Security.
      eodhd_exchange = MIC_TO_EODHD_EXCHANGE[exchange_operating_mic] ||
        MIC_TO_EODHD_EXCHANGE[::Security.canonical_exchange_operating_mic(exchange_operating_mic)]
      symbol_key = symbol.to_s.upcase
      cache_keys = [
        "eodhd:currency:#{symbol_key}:#{exchange_operating_mic}",
        "eodhd:currency:#{symbol_key}:#{::Security.canonical_exchange_operating_mic(exchange_operating_mic)}"
      ].uniq

      cache_keys.lazy.map { |key| Rails.cache.read(key) }.find(&:present?) ||
        EXCHANGE_CURRENCY[eodhd_exchange] ||
        EXCHANGE_CURRENCY[exchange_operating_mic]
    end

    # Cache key for tracking daily API usage
    def daily_cache_key
      "eodhd:daily:#{Date.current}"
    end

    # Runs on every HTTP attempt through BeforeEachAttempt, so a retried request
    # is throttled and reserved again. The billing cost comes from the request
    # URL (fundamentals are billed at ten API calls), falling back to
    # `@request_cost` for fake clients in tests that don't carry one. The last
    # key reserved against is remembered so a refund lands on the day the
    # attempt ran, even when midnight falls between the reservation and the
    # failure.
    def count_request_attempt!(url = nil)
      # Check the budget first so an over-quota attempt fails fast instead of
      # sleeping the full interval before being refused.
      reserve_daily_limit!(cost: url ? billing_cost_for(url.to_s) : (@request_cost || 1))
      throttle_request
    end

    def reserve_daily_limit!(cost: 1)
      @last_counted_on = enforce_daily_limit!(cost: cost)
    end

    def last_counted_on
      @last_counted_on || daily_cache_key
    end

    # Clears the per-request billing state after a request finishes, so a later
    # plain request on this instance is not billed at a stale higher cost.
    def reset_request_cost!
      @request_cost = nil
      @last_counted_on = nil
    end

    # EODHD bills a fundamentals request as 10 API calls; everything else is one.
    def billing_cost_for(url)
      url.to_s.include?("/api/fundamentals/") ? FUNDAMENTALS_REQUEST_COST : 1
    end

    # Enforces the daily rate limit. Raises RateLimitError if the limit is exhausted.
    # Uses atomic increment-then-check to avoid TOCTOU races between concurrent workers.
    # `cost` is how many API calls EODHD bills for the request. A refused request is
    # taken back off the count, so a refused fundamentals call leaves the rest for prices.
    # Between the increment and the refund a concurrent request sees the higher count and
    # may be refused although it would fit; that costs it one retry on the next sync.
    # Returns the counter key, so a later refund goes to the same day even after midnight.
    def enforce_daily_limit!(cost: 1)
      key = daily_cache_key
      new_count = Rails.cache.increment(key, cost, expires_in: 24.hours).to_i

      if new_count > max_requests_per_day
        refund_daily_requests(cost, key: key)
        raise RateLimitError, "EODHD daily rate limit of #{max_requests_per_day} requests exhausted"
      end

      key
    end

    # Takes requests back off the count they were added to. If the counter vanished in
    # the meantime (evicted, or the cache cleared), the decrement recreates it below zero;
    # put it back to zero so it does not hand out free requests.
    def refund_daily_requests(amount, key:)
      count = Rails.cache.decrement(key, amount, expires_in: 24.hours).to_i
      Rails.cache.increment(key, -count, expires_in: 24.hours) if count.negative?
    end

    # throttle_request and min_request_interval provided by RateLimitable

    def max_requests_per_day
      ENV.fetch("EODHD_MAX_REQUESTS_PER_DAY", MAX_REQUESTS_PER_DAY).to_i
    end

    def check_api_error!(parsed)
      return unless parsed.is_a?(Hash) && parsed["error"].present?

      raise Error, "API error: #{parsed["error"]}"
    end
end
