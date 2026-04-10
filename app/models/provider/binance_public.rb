class Provider::BinancePublic < Provider
  include SecurityConcept, RateLimitable
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  MIN_REQUEST_INTERVAL = 0.1

  # Binance's official ISO 10383 operating MIC (assigned Jan 2026, country AE).
  BINANCE_MIC = "BNCX".freeze
  BINANCE_COUNTRY = "AE".freeze

  # Quote assets we expose in search results. Order = preference when multiple
  # quote variants exist for the same base asset. USDT is Binance's dominant
  # dollar quote and is surfaced to users as USD.
  SUPPORTED_QUOTES = %w[USDT EUR GBP TRY].freeze

  # Binance quote asset -> user-facing currency & ticker suffix.
  QUOTE_TO_CURRENCY = {
    "USDT" => "USD",
    "EUR"  => "EUR",
    "GBP"  => "GBP",
    "TRY"  => "TRY"
  }.freeze

  KLINE_MAX_LIMIT = 1000
  MS_PER_DAY = 24 * 60 * 60 * 1000
  SEARCH_LIMIT = 25

  def initialize
    # No API key required — public market data only.
  end

  def healthy?
    with_provider_response do
      client.get("#{base_url}/api/v3/ping")
      true
    end
  end

  def usage
    with_provider_response do
      UsageData.new(used: nil, limit: nil, utilization: nil, plan: "Free (no key required)")
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      query = symbol.to_s.strip.upcase
      next [] if query.empty?

      symbols = exchange_info_symbols

      matches = symbols.select do |s|
        base = s["baseAsset"].to_s.upcase
        quote = s["quoteAsset"].to_s.upcase
        SUPPORTED_QUOTES.include?(quote) && base.include?(query)
      end

      ranked = matches.sort_by do |s|
        base = s["baseAsset"].to_s.upcase
        quote_index = SUPPORTED_QUOTES.index(s["quoteAsset"].to_s.upcase) || 99
        relevance = if base == query
          0
        elsif base.start_with?(query)
          1
        else
          2
        end
        [ relevance, quote_index, base ]
      end

      ranked.first(SEARCH_LIMIT).map do |s|
        base = s["baseAsset"].to_s.upcase
        quote = s["quoteAsset"].to_s.upcase
        display_currency = QUOTE_TO_CURRENCY[quote]

        Security.new(
          symbol: "#{base}#{display_currency}",
          name: base,
          logo_url: nil,
          exchange_operating_mic: BINANCE_MIC,
          country_code: BINANCE_COUNTRY,
          currency: display_currency
        )
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      parsed = parse_ticker(symbol)
      raise Error, "Unsupported Binance ticker: #{symbol}" if parsed.nil?

      SecurityInfo.new(
        symbol: symbol,
        name: parsed[:base],
        links: "https://www.binance.com/en/trade/#{parsed[:binance_pair]}",
        logo_url: nil,
        description: nil,
        kind: "crypto",
        exchange_operating_mic: exchange_operating_mic
      )
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic:, date:)
    with_provider_response do
      historical = fetch_security_prices(
        symbol: symbol,
        exchange_operating_mic: exchange_operating_mic,
        start_date: date,
        end_date: date
      )

      raise historical.error if historical.error.present?
      raise InvalidSecurityPriceError, "No price found for #{symbol} on #{date}" if historical.data.blank?

      historical.data.first
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic:, start_date:, end_date:)
    with_provider_response do
      parsed = parse_ticker(symbol)
      raise InvalidSecurityPriceError, "Unsupported Binance ticker: #{symbol}" if parsed.nil?

      binance_pair = parsed[:binance_pair]
      display_currency = parsed[:display_currency]
      prices = []
      cursor = start_date

      while cursor <= end_date
        window_end = [ cursor + (KLINE_MAX_LIMIT - 1).days, end_date ].min

        throttle_request
        response = client.get("#{base_url}/api/v3/klines") do |req|
          req.params["symbol"]    = binance_pair
          req.params["interval"]  = "1d"
          req.params["startTime"] = date_to_ms(cursor)
          req.params["endTime"]   = date_to_ms(window_end) + MS_PER_DAY - 1
          req.params["limit"]     = KLINE_MAX_LIMIT
        end

        batch = JSON.parse(response.body)
        break if batch.blank?

        batch.each do |row|
          open_time_ms = row[0].to_i
          close_price  = row[4].to_f
          next if close_price <= 0

          prices << Price.new(
            symbol: symbol,
            date: Time.at(open_time_ms / 1000).utc.to_date,
            price: close_price,
            currency: display_currency,
            exchange_operating_mic: exchange_operating_mic
          )
        end

        # Binance returned fewer rows than asked for → we're at the tail of
        # available history, no point paginating further.
        break if batch.size < KLINE_MAX_LIMIT

        cursor = window_end + 1.day
      end

      prices
    end
  end

  private
    def base_url
      ENV["BINANCE_PUBLIC_URL"] || "https://data-api.binance.vision"
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.request(:retry, {
          max: 3,
          interval: 0.5,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        })

        faraday.request :json
        faraday.response :raise_error
        faraday.headers["Accept"] = "application/json"
      end
    end

    # Maps a user-visible ticker (e.g. "BTCUSD", "ETHEUR") to the Binance pair
    # symbol, base asset, and display currency. Returns nil if the ticker does
    # not end with a supported quote currency.
    def parse_ticker(ticker)
      ticker_up = ticker.to_s.upcase
      SUPPORTED_QUOTES.each do |quote|
        display_currency = QUOTE_TO_CURRENCY[quote]
        next unless ticker_up.end_with?(display_currency)

        base = ticker_up.delete_suffix(display_currency)
        next if base.empty?

        return { binance_pair: "#{base}#{quote}", base: base, display_currency: display_currency }
      end
      nil
    end

    # Cached for 24h — exchangeInfo returns the full symbol universe (thousands
    # of rows, weight 10) and rarely changes.
    def exchange_info_symbols
      Rails.cache.fetch("binance_public:exchange_info", expires_in: 24.hours) do
        throttle_request
        response = client.get("#{base_url}/api/v3/exchangeInfo")
        parsed = JSON.parse(response.body)
        (parsed["symbols"] || []).select { |s| s["status"] == "TRADING" }
      end
    end

    def date_to_ms(date)
      Time.utc(date.year, date.month, date.day).to_i * 1000
    end

    # Preserve BinancePublic::Error subclasses (e.g. InvalidSecurityPriceError)
    # through with_provider_response. The inherited RateLimitable transformer
    # only preserves RateLimitError and would otherwise downcast our custom
    # errors to the generic Error class.
    def default_error_transformer(error)
      return error if error.is_a?(self.class::Error)
      super
    end
end
