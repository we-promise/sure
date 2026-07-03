# T-Bank (Tinkoff) Invest API securities provider, built on the token-based REST
# gateway (https://invest-public-api.tinkoff.ru/rest) over the public gRPC
# contract. Mirrors the keyed providers (Tiingo/TwelveData) for auth and the
# keyless market providers (MoexPublic/BinancePublic) for SslConfigurable +
# RateLimitable plumbing.
#
# Why it exists: ISS (MoexPublic) prices Russian instruments but carries no
# logos. T-Invest is the authoritative source of instrument *brand logos*
# (shares, ETF/БПИФ, bonds) via its CDN, and can also serve prices for those
# instruments when MOEX is not the selected provider. The app therefore uses it
# two ways:
#   1. As a securities price/search provider (when enabled in settings).
#   2. As a brand-logo source consulted by Security#import_provider_details
#      regardless of which provider prices the security (see Security::Provided),
#      so MOEX-priced holdings still get real logos.
#
# REST shape: every call is POST to
#   /tinkoff.public.invest.api.contract.v1.<Service>/<Method>
# with a JSON body, Bearer-token auth, and a JSON response. Money is encoded as
# Quotation { units: "<int>", nano: <int> } => units + nano/1e9.
class Provider::TinkoffInvest < Provider
  include SecurityConcept, RateLimitable
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  # T-Invest unary REST limits are generous (hundreds/min); space calls lightly.
  MIN_REQUEST_INTERVAL = 0.1

  # gRPC-over-REST service path prefix.
  API_NS = "tinkoff.public.invest.api.contract.v1".freeze

  # Brand-logo CDN. The API returns brand.logoName like "SBER.png"; the image is
  # served at <CDN>/<logoName without extension><size>.png — sizes x160/x320/x640.
  LOGO_CDN = "https://invest-brands.cdn-tinkoff.ru".freeze
  LOGO_SIZE = "x160".freeze

  # ISO 10383 operating MICs we surface. T-Invest mostly covers MOEX; SPB Exchange
  # instruments map to XSPX. Anything else stays nil (resolver wildcard).
  MOEX_MIC = "MISX".freeze
  SPB_MIC = "XSPX".freeze

  # GetCandles caps the window per request by interval; for daily candles we page
  # in ~1-year chunks and bound the loop defensively.
  CANDLE_CHUNK_DAYS = 360
  MAX_CANDLE_PAGES = 60

  INSTRUMENT_CACHE_TTL = 24.hours
  SEARCH_CACHE_TTL = 5.minutes

  def initialize(api_key)
    @api_key = api_key # pipelock:ignore
  end

  def healthy?
    with_provider_response do
      post("InstrumentsService", "FindInstrument", query: "SBER", instrumentKind: "INSTRUMENT_TYPE_SHARE")
      true
    end
  end

  def usage
    with_provider_response do
      UsageData.new(used: nil, limit: nil, utilization: nil, plan: "Token (read-only)")
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      query = symbol.to_s.strip
      next [] if query.empty?

      find_instruments(query).filter_map do |row|
        next nil unless row["apiTradeAvailableFlag"] # only surface instruments the API can actually price
        next nil unless surfaced_kind(row["instrumentType"])

        Provider::SecurityConcept::Security.new(
          symbol: row["ticker"].to_s,
          name: (row["name"].presence || row["ticker"]).to_s,
          logo_url: nil, # FindInstrument carries no brand; logos come from #fetch_security_info
          exchange_operating_mic: mic_for(row["classCode"], row["exchange"]),
          country_code: row["countryOfRisk"].presence,
          currency: row["currency"].to_s.upcase.presence
        )
      end.uniq { |s| [ s.symbol, s.exchange_operating_mic ] }
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      short = resolve_short(symbol, exchange_operating_mic)
      raise Error, "Unknown T-Invest instrument: #{symbol}" if short.nil?

      detail = instrument_detail(short["uid"])

      SecurityInfo.new(
        symbol: short["ticker"].to_s,
        name: (detail["name"].presence || short["name"]).to_s,
        links: nil, # T-Invest exposes no issuer website
        logo_url: logo_url(detail.dig("brand", "logoName")),
        description: nil,
        kind: surfaced_kind(short["instrumentType"]),
        exchange_operating_mic: mic_for(short["classCode"], detail["exchange"])
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
      raise InvalidSecurityPriceError, "No T-Invest price for #{symbol} on #{date}" if historical.data.blank?

      historical.data.find { |p| p.date == date } ||
        historical.data.select { |p| p.date <= date }.max_by(&:date) ||
        historical.data.first
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic:, start_date:, end_date:)
    with_provider_response do
      short = resolve_short(symbol, exchange_operating_mic)
      raise Error, "Unknown T-Invest instrument: #{symbol}" if short.nil?

      uid = short["uid"]
      bond = short["instrumentType"].to_s == "bond"
      currency = short["currency"].to_s.upcase
      mic = mic_for(short["classCode"], short["exchange"])

      # Bonds quote in % of par; multiply by nominal to get a money price. A
      # missing/invalid nominal is a provider-data failure, not a zero price.
      nominal = nil
      amortizing = false
      if bond
        info = bond_info(uid)
        nominal = info[:nominal]
        amortizing = info[:amortizing]
        raise InvalidSecurityPriceError, "Missing or invalid T-Invest bond nominal for #{symbol}" if nominal.nil? || nominal <= 0
      end

      ticker = short["ticker"].to_s
      build = ->(date, raw) { Price.new(symbol: ticker, date: date, price: (bond ? (raw / 100) * nominal : raw), currency: currency, exchange_operating_mic: mic) }

      # BondBy returns only the CURRENT nominal. For an amortizing bond the par
      # shrinks over time, so applying today's nominal to historical percent-of-
      # par closes would underprice them — skip the candle history and return
      # just the live price. Fixed-par bonds and equities use full history.
      prices = (bond && amortizing) ? [] : candle_closes(uid, start_date, end_date).map { |date, close| build.call(date, close) }

      # The candle endpoint lags the live session; append the last price for a
      # range reaching today.
      if end_date >= Date.current
        last = last_price(uid)
        if last
          prices.reject! { |p| p.date == Date.current }
          prices << build.call(Date.current, last)
        end
      end

      prices.sort_by(&:date)
    end
  end

  def max_history_days
    nil # GetCandles serves the instrument's full daily history (paged).
  end

  private

    attr_reader :api_key

    # ================================
    #          HTTP / parsing
    # ================================

    def base_url
      ENV["TINKOFF_INVEST_URL"].presence || "https://invest-public-api.tinkoff.ru/rest"
    end

    def post(service, method, body)
      throttle_request
      response = client.post("#{base_url}/#{API_NS}.#{service}/#{method}") do |req|
        req.body = body.to_json
      end
      JSON.parse(response.body)
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.options.open_timeout = 5
        faraday.options.timeout = 20

        faraday.request(:retry, {
          max: 3,
          interval: 0.5,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        })

        faraday.headers["Authorization"] = "Bearer #{api_key}"
        faraday.headers["Content-Type"] = "application/json"
        faraday.headers["Accept"] = "application/json"
        faraday.response :raise_error
      end
    end

    # Quotation { units, nano } -> BigDecimal. Absent/blank -> nil.
    def quotation_to_d(q)
      return nil if q.blank?
      units = BigDecimal(q["units"].to_s.presence || "0")
      nano = BigDecimal(q["nano"].to_s.presence || "0")
      units + (nano / BigDecimal("1000000000"))
    end

    # ================================
    #           Instruments
    # ================================

    # Users (and the MoexPublic resolver) paste exchange-suffixed tickers like
    # "T.MOEX"/"SBER.ME"; T-Invest only knows the bare SECID, so strip the suffix
    # before querying.
    SUFFIX = /\.(ME|MOEX|MISX|MCX)\z/i

    def find_instruments(query)
      q = query.to_s.strip.sub(SUFFIX, "")
      Rails.cache.fetch("tinkoff_invest:find:#{q.downcase}", expires_in: SEARCH_CACHE_TTL) do
        # Return all matches (not just apiTradeAvailableFlag) — a ticker can have
        # several non-tradeable listings plus one tradeable board; resolve_short
        # ranks the tradeable one first while keeping a fallback for instruments
        # Tinkoff lists but can't trade via API.
        body = post("InstrumentsService", "FindInstrument", query: q)
        body["instruments"] || []
      end
    end

    # Best FindInstrument hit for a ticker/ISIN. A ticker like SBER returns many
    # listings (TQBR, SPB, dark boards). When the caller supplied a MIC, honor it
    # FIRST so a security is never priced off another exchange's listing; then
    # prefer the API-tradeable board (the one with live prices), then an exact
    # ticker/ISIN match.
    def resolve_short(symbol, exchange_operating_mic)
      key = symbol.to_s.strip.sub(SUFFIX, "")
      # skip_nil so a transient empty/no-match response isn't cached as "unknown"
      # for the full 24h TTL.
      Rails.cache.fetch("tinkoff_invest:short:#{key.downcase}:#{exchange_operating_mic}", expires_in: INSTRUMENT_CACHE_TTL, skip_nil: true) do
        rows = find_instruments(key)
        up = key.upcase

        exact = rows.select { |r| r["ticker"].to_s.upcase == up || r["isin"].to_s.upcase == up }
        pool = exact.any? ? exact : rows
        typed = pool.select { |r| surfaced_kind(r["instrumentType"]) }
        pool = typed if typed.any?
        next nil if pool.empty?

        mic = exchange_operating_mic.to_s.upcase
        pool.min_by do |r|
          [
            (mic.present? && mic_for(r["classCode"], r["exchange"]) == mic) ? 0 : 1,
            r["apiTradeAvailableFlag"] ? 0 : 1,
            (r["ticker"].to_s.upcase == up || r["isin"].to_s.upcase == up) ? 0 : 1
          ]
        end
      end
    end

    # GetInstrumentBy(uid) — full instrument incl. brand/logo, exchange, nominal.
    def instrument_detail(uid)
      Rails.cache.fetch("tinkoff_invest:detail:#{uid}", expires_in: INSTRUMENT_CACHE_TTL) do
        body = post("InstrumentsService", "GetInstrumentBy", idType: "INSTRUMENT_ID_TYPE_UID", id: uid)
        body["instrument"] || {}
      end
    end

    # Bond nominal + amortization flag from BondBy (the generic GetInstrumentBy
    # omits nominal). `nominal` is the current (possibly amortized) par;
    # `amortizing` tells the price path that historical par differs from today's.
    def bond_info(uid)
      body = post("InstrumentsService", "BondBy", idType: "INSTRUMENT_ID_TYPE_UID", id: uid)
      ins = body["instrument"] || {}
      { nominal: quotation_to_d(ins["nominal"]), amortizing: ins["amortizationFlag"] == true }
    end

    # ================================
    #             Prices
    # ================================

    def candle_closes(uid, start_date, end_date)
      return [] if start_date > end_date

      closes = {}
      window_start = start_date
      pages = 0

      while window_start <= end_date && pages < MAX_CANDLE_PAGES
        window_end = [ window_start + CANDLE_CHUNK_DAYS, end_date ].min
        body = post(
          "MarketDataService", "GetCandles",
          instrumentId: uid,
          interval: "CANDLE_INTERVAL_DAY",
          from: "#{window_start}T00:00:00Z",
          to: "#{window_end}T23:59:59Z"
        )

        (body["candles"] || []).each do |c|
          next unless c["isComplete"]
          date = parse_time(c["time"])
          close = quotation_to_d(c["close"])
          closes[date] = close if date && close && close > 0
        end

        pages += 1
        window_start = window_end + 1
      end

      closes.sort.to_h.map { |date, close| [ date, close ] }
    end

    def last_price(uid)
      body = post("MarketDataService", "GetLastPrices", instrumentId: [ uid ])
      row = (body["lastPrices"] || []).first
      return nil unless row
      value = quotation_to_d(row["price"])
      value if value && value > 0
    end

    # ================================
    #            Helpers
    # ================================

    def logo_url(logo_name)
      return nil if logo_name.blank?
      "#{LOGO_CDN}/#{logo_name.to_s.sub(/\.png\z/i, '')}#{LOGO_SIZE}.png"
    end

    # T-Invest instrumentType -> the security kinds we surface (skip futures,
    # currencies, options, etc.).
    def surfaced_kind(instrument_type)
      case instrument_type.to_s.downcase
      when "share" then "stock"
      when "etf" then "fund"
      when "bond" then "bond"
      end
    end

    def mic_for(class_code, exchange)
      ex = exchange.to_s.downcase
      return MOEX_MIC if class_code.to_s.start_with?("TQ") || ex.include?("moex")
      return SPB_MIC if ex.include?("spb")
      nil
    end

    def parse_time(raw)
      return nil if raw.blank?
      Date.parse(raw.to_s)
    rescue Date::Error
      nil
    end

    # Preserve TinkoffInvest::Error subclasses through with_provider_response,
    # mirroring MoexPublic/BinancePublic.
    def default_error_transformer(error)
      return error if error.is_a?(self.class::Error)
      super
    end
end
