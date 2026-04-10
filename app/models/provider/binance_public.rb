class Provider::BinancePublic < Provider
  include SecurityConcept, RateLimitable
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  MIN_REQUEST_INTERVAL = 0.1

  # Binance's official ISO 10383 operating MIC (assigned Jan 2026, country AE).
  # Crypto is not tied to a national jurisdiction, so we intentionally do NOT
  # propagate the ISO-assigned country code to search results — the resolver
  # treats a nil candidate country as a wildcard, letting any family resolve
  # a Binance pick regardless of their own country.
  BINANCE_MIC = "BNCX".freeze

  # Quote assets we expose in search results. Order = preference when multiple
  # quote variants exist for the same base asset. USDT is Binance's dominant
  # dollar quote and is surfaced to users as USD. GBP is absent because
  # Binance has zero GBP trading pairs today; GBP-family users fall back to
  # USDT->USD via the app's FX conversion, same as HUF/CZK/PLN users.
  SUPPORTED_QUOTES = %w[USDT EUR JPY BRL TRY].freeze

  # Binance quote asset -> user-facing currency & ticker suffix.
  QUOTE_TO_CURRENCY = {
    "USDT" => "USD",
    "EUR"  => "EUR",
    "JPY"  => "JPY",
    "BRL"  => "BRL",
    "TRY"  => "TRY"
  }.freeze

  # Per-asset logo PNGs served via jsDelivr from a GitHub repo that tracks the
  # full Binance-listed asset set. We originally used bin.bnbstatic.com directly
  # — Binance's own CDN — but that host enforces Referer-based hotlink
  # protection at CloudFront: any request with a non-Binance Referer returns
  # 403. A server-side HEAD from Faraday (no Referer) succeeds, which masked
  # the breakage until the URL hit an actual <img> tag in the browser. jsDelivr
  # is CORS-open and hotlink-friendly, so the URL we persist is the URL the
  # browser can actually load. File names are uppercase PNGs (BTC.png, ETH.png).
  LOGO_CDN_BASE = "https://cdn.jsdelivr.net/gh/lindomar-oliveira/binance-data-plus/assets/img".freeze

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
        base   = s["baseAsset"].to_s.upcase
        quote  = s["quoteAsset"].to_s.upcase
        symbol = s["symbol"].to_s.upcase

        next false unless SUPPORTED_QUOTES.include?(quote)

        # Match on either the base asset (so "BTC" surfaces every BTC pair) or
        # the full Binance pair symbol (so users pasting their own portfolio
        # ticker like "BTCEUR" or "BTCUSD" — which prefixes Binance's raw
        # "BTCUSDT" — also hit a result).
        base.include?(query) || symbol == query || symbol.start_with?(query)
      end

      ranked = matches.sort_by do |s|
        base   = s["baseAsset"].to_s.upcase
        quote  = s["quoteAsset"].to_s.upcase
        symbol = s["symbol"].to_s.upcase
        quote_index = SUPPORTED_QUOTES.index(quote) || 99

        relevance = if symbol == query
          0 # exact full-ticker match — highest priority
        elsif symbol.start_with?(query)
          1 # ticker prefix match (e.g. "BTCUSD" against "BTCUSDT")
        elsif base == query
          2 # exact base-asset match (e.g. "BTC")
        elsif base.start_with?(query)
          3
        else
          4
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
          logo_url: "#{LOGO_CDN_BASE}/#{base}.png",
          exchange_operating_mic: BINANCE_MIC,
          country_code: nil,
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
        logo_url: verified_logo_url(parsed[:base]),
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
      seen_data = false

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

        if batch.empty?
          # Empty window. Two cases:
          #   1. cursor is before the pair's listing date — keep advancing
          #      until we hit the first window containing valid klines.
          #      Critical for long-range imports (e.g. account sync from a
          #      trade start date that predates the Binance listing).
          #   2. We have already collected prices and this window is past
          #      the end of available history — stop to avoid wasted calls
          #      on delisted pairs.
          break if seen_data
        else
          seen_data = true
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
        end

        # Note: we intentionally do NOT break on a short (non-empty) batch.
        # A window that straddles the pair's listing date legitimately returns
        # fewer than KLINE_MAX_LIMIT rows while there is still valid data in
        # subsequent windows.
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
        # Explicit timeouts so a hanging Binance endpoint can't stall a Sidekiq
        # worker or Puma thread indefinitely. Values are deliberately generous
        # enough for a full 1000-row klines response but capped to bound the
        # worst-case retry chain (3 attempts * 20s + backoff ~= 65s).
        faraday.options.open_timeout = 5
        faraday.options.timeout      = 20

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

    # Returns the asset-specific jsDelivr logo URL if the HEAD succeeds, else
    # nil. Returning nil (rather than a hard-coded fallback URL) lets
    # Security#display_logo_url swap in a Brandfetch binance.com URL at render
    # time — a config-dependent path that can't be baked into a constant here.
    # Cached per base asset for 30 days so we HEAD at most once per coin and
    # only when Security#import_provider_details runs (never during search,
    # which must stay fast).
    def verified_logo_url(base_asset)
      Rails.cache.fetch("binance_public:logo:#{base_asset}", expires_in: 30.days) do
        candidate = "#{LOGO_CDN_BASE}/#{base_asset}.png"
        logo_client.head(candidate)
        candidate
      rescue Faraday::Error
        nil
      end
    end

    # Dedicated Faraday client for the logo CDN host (jsdelivr.net is a
    # different origin from data-api.binance.vision). HEAD-only with a tight
    # timeout so CDN hiccups can't stall Security info imports.
    def logo_client
      @logo_client ||= Faraday.new(url: LOGO_CDN_BASE, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.options.timeout = 3
        faraday.options.open_timeout = 2
        faraday.response :raise_error
      end
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
