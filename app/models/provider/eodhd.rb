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

  # The fundamentals response carries `General.Sector` / `General.Industry`,
  # so this provider can answer for classification -- see
  # `fetch_security_info` below. Without this declaration the classification
  # gate in `Security::Provided` would never ask it.
  def supplies_classification?
    true
  end

  # The same response carries `ETF_Data.Holdings` for a fund -- see
  # `etf_constituents` below.
  def supplies_constituents?
    true
  end

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

      counted_on = enforce_daily_limit!(cost: FUNDAMENTALS_REQUEST_COST)
      throttle_request

      begin
        response = client.get("#{base_url}/api/fundamentals/#{CGI.escape(ticker)}") do |req|
          req.params["api_token"] = api_key
          req.params["fmt"] = "json"
        end

        parsed = JSON.parse(response.body)
        check_api_error!(parsed)
      rescue Faraday::ForbiddenError, Faraday::ResourceNotFound, Error => e
        Rails.cache.write(failed_key, true, expires_in: 7.days)
        # EODHD documents that a lookup for an unknown ticker (404) is billed at its
        # full price, but not whether a request the plan does not include (403, e.g.
        # fundamentals on the free plan) is. Count it as one request rather than ten:
        # under-counting a refused call is safer than refusing the day's prices.
        # An error in a 200 answer (Error, from check_api_error!) was served, and
        # EODHD bills failed lookups, so it keeps its full price.
        refund_daily_requests(FUNDAMENTALS_REQUEST_COST - 1, key: counted_on) if e.is_a?(Faraday::ForbiddenError)
        raise
      rescue Faraday::ClientError => e
        # EODHD answers 402 when the day's calls are used up and does not bill it
        refund_daily_requests(FUNDAMENTALS_REQUEST_COST, key: counted_on) if e.response_status == 402
        raise
      end

      general = parsed.dig("General") || {}

      SecurityInfo.new(
        symbol: symbol,
        name: general.dig("Name"),
        links: general.dig("WebURL"),
        logo_url: general.dig("LogoURL"),
        description: general.dig("Description"),
        kind: general.dig("Type"),
        exchange_operating_mic: exchange_operating_mic,
        sector: general.dig("Sector"),
        industry: general.dig("Industry"),
        constituents: etf_constituents(parsed),
        fund_weights: fund_weights_from(parsed["ETF_Data"] || parsed["MutualFund_Data"], category: fund_category(parsed))
      )
    end
  end

  # A fund's own holdings, from the SAME fundamentals response the metadata and
  # the classification already come from -- so they cost no additional request.
  #
  # EODHD keys the holdings hash by a suffixed ticker ("AAPL.US") and carries the
  # bare one in `Code`. The bare ticker is what matches anything in `securities`,
  # so the key is used only as a fallback for a malformed entry.
  #
  # An absent or empty block means the fund lists nothing. Any other shape is
  # a response this cannot read, and raises: answered as "no holdings", it
  # would replace the fund's stored set with nothing and stamp it as asked.
  def etf_constituents(parsed)
    holdings = parsed.dig("ETF_Data", "Holdings")
    return nil if holdings.blank?
    raise Error, "Unexpected holdings format from fundamentals API" unless holdings.is_a?(Hash)

    holdings.filter_map do |key, holding|
      next unless holding.is_a?(Hash)

      ticker = holding["Code"].presence || key.to_s.split(".").first
      next if ticker.blank?

      { ticker: ticker, name: holding["Name"].presence, weight: holding["Assets_%"] }
    end.presence
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
      enforce_daily_limit!
      throttle_request

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

    # EODHD's fund breakdown labels, mapped to Security::ASSET_CLASSES and
    # Security::REGION_KEYS. ETF_Data and MutualFund_Data use different labels
    # for the same buckets. "Other", "NotClassified", "Preferred" and
    # "Convertible" map to nothing: they count towards the fund but not
    # towards any class.
    FUND_ASSET_CLASSES = {
      "Stock US" => "equity", "Stock non-US" => "equity", "US Stocks" => "equity", "Non US Stocks" => "equity",
      "Bond" => "fixed_income", "Bonds" => "fixed_income",
      "Cash" => "liquidity"
    }.freeze

    # A fund's category (Morningstar-style: "Large Blend", "Commodities Broad
    # Basket", "Trading--Inverse Equity", "Money Market-Taxable") says what it
    # is for when its holdings cannot: a commodity-futures ETF holds mostly
    # T-bills as collateral, and an inverse ETF holds a short position plus
    # cash. First match wins, so an inverse commodity fund is inverse.
    FUND_WEIGHT_TOLERANCE = 10

    FUND_CATEGORIES = [
      [ /leverag|inverse/i, :leveraged_or_inverse ],
      [ /equity/i, nil ], # "Equity Precious Metals" (GDX) holds miners, not metal
      [ /commodit|precious metal/i, "commodity" ],
      [ /money market/i, "liquidity" ]
    ].freeze

    FUND_REGIONS = {
      "North America" => "north_america",
      "Latin America" => "latin_america",
      "United Kingdom" => "europe", "Europe Developed" => "europe", "Europe Emerging" => "europe",
      "Africa/Middle East" => "middle_east_africa",
      "Japan" => "asia_pacific", "Australasia" => "asia_pacific",
      "Asia Developed" => "asia_pacific", "Asia Emerging" => "asia_pacific"
    }.freeze

    # ETF_Data keys its breakdowns by label:
    #   "Asset_Allocation" => { "Stock US" => { "Net_Assets_%" => "60.1" } }
    #   "World_Regions"    => { "North America" => { "Equity_%" => "61.2" } }
    #   "Sector_Weights"   => { "Technology" => { "Equity_%" => "24.5" } }
    # MutualFund_Data groups regions and sectors into lists:
    #   "Asset_Allocation" => { "US Stocks" => { "Net_%" => "60.1" } }
    #   "World_Regions"    => { "Americas" => [ { "Name" => "North America", "Stocks_%" => "61.2" } ] }
    #   "Sector_Weights"   => { "Cyclical" => [ { "Type" => "Basic Materials", "Amount_%" => "2.5" } ] }
    #
    # World_Regions and Sector_Weights are percentages of the fund's EQUITY
    # sleeve (Equity_%, Stocks_%), not of the whole fund.
    #
    # A negative net allocation (a short position) marks the fund as
    # leveraged or inverse, the same as a category that says so.
    def fund_weights_from(fund_data, category: nil)
      return nil unless fund_data.is_a?(Hash)

      category_answer = FUND_CATEGORIES.find { |pattern, _| category.to_s.match?(pattern) }&.last
      net_keys = %w[Net_Assets_% Net_%]
      # Settlement and TBA rolls leave long-only funds a few percent short on cash.
      short = fund_net_allocations(fund_data["Asset_Allocation"], net_keys).any? { |percent| percent < -FUND_WEIGHT_TOLERANCE }

      weights = {
        asset_class: sum_fund_weights(fund_data["Asset_Allocation"], FUND_ASSET_CLASSES, net_keys),
        equity_region: sum_fund_weights(fund_data["World_Regions"], FUND_REGIONS, %w[Equity_% Stocks_%]),
        equity_sector: sum_fund_weights(fund_data["Sector_Weights"], nil, %w[Equity_% Amount_%]),
        category_asset_class: category_answer.is_a?(String) ? category_answer : nil,
        leveraged_or_inverse: (short || category_answer == :leveraged_or_inverse) || nil
      }.compact_blank

      weights.presence
    end

    def fund_category(parsed)
      fund_data = parsed["ETF_Data"] || parsed["MutualFund_Data"]
      fund_data = {} unless fund_data.is_a?(Hash)
      general = parsed["General"].is_a?(Hash) ? parsed["General"] : {}

      [ general["Category"], fund_data["Category"], fund_data["Fund_Category"] ].find { |value| value.is_a?(String) && value.present? }
    end

    # Every net percentage in the allocation, mapped or not ("Other" counts too).
    def fund_net_allocations(section, value_keys)
      return [] unless section.is_a?(Hash)

      section.values.filter_map do |row|
        next unless row.is_a?(Hash)

        value_keys.lazy.map { |key| row[key] }.find(&:present?)&.to_f
      end
    end

    # Sums each entry's percentage into its mapped bucket. With no mapping the
    # provider's own label is the bucket (sectors are free text).
    def sum_fund_weights(section, mapping, value_keys)
      entries =
        case section
        when Hash
          section.flat_map do |label, value|
            value.is_a?(Array) ? value.filter_map { |row| [ row["Name"] || row["Type"], row ] if row.is_a?(Hash) } : [ [ label, value ] ]
          end
        else
          []
        end

      entries.each_with_object(Hash.new(0.0)) do |(label, row), totals|
        next unless row.is_a?(Hash)

        bucket = mapping ? mapping[label] : label.presence
        percent = value_keys.lazy.map { |key| row[key] }.find(&:present?)
        next if bucket.nil? || percent.nil?

        totals[bucket] += percent.to_f
      end.to_h
    end

    # Cache key for tracking daily API usage
    def daily_cache_key
      "eodhd:daily:#{Date.current}"
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
