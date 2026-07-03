# Moscow Exchange (MOEX) market-data provider built on the free, keyless ISS
# API (https://iss.moex.com/iss). Mirrors Provider::BinancePublic: no API key,
# public endpoints only, Faraday client with retry/timeouts, RateLimitable
# throttling, and SslConfigurable for self-hosted CA support.
#
# Covers Russian-market instruments that Yahoo dropped after 2022 — shares,
# funds/ETF/БПИФ (e.g. LQDT), and bonds (OFZ + corporate) — and doubles as an
# exchange-rate provider for RUB↔{USD,EUR,CNY} via the selt (FX) market.
#
# ISS responses are column-array JSON: each block is { "columns" => [...],
# "data" => [[...], ...] }. We index every row by lowercased column name so the
# code tolerates ISS reordering or casing differences across endpoints.
class Provider::MoexPublic < Provider
  include SecurityConcept, ExchangeRateConcept, RateLimitable
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  # ISS is generous but we still space requests to be a good citizen.
  MIN_REQUEST_INTERVAL = 0.15

  # Moscow Exchange ISO 10383 operating MIC. Like BinancePublic we intentionally
  # do NOT propagate a country code to search results — the resolver treats a nil
  # candidate country as a wildcard, so any family resolves a MOEX pick.
  MOEX_MIC = "MISX".freeze

  # Hardcoded board preference, consulted only when ISS does not flag a primary
  # board. Shares (TQBR), ETF/funds (TQTF/TQIF), OFZ (TQOB), corporate/exchange
  # bonds (TQCB/TQIR), USD/EUR-settled boards (TQTD/TQOD/TQOE/TQTE), restructured
  # (TQRD). Earlier = higher priority.
  BOARD_PRIORITY = %w[TQBR TQTF TQIF TQOB TQCB TQIR TQRD TQTD TQOD TQOE TQTE].freeze

  # selt FX instruments quoted as roubles per 1 unit of the foreign currency
  # (X/RUB). TOM = tomorrow settlement, the liquid benchmark line.
  FX_INSTRUMENTS = {
    "USD" => "USD000UTSTOM",
    "EUR" => "EUR_RUB__TOM",
    "CNY" => "CNYRUB_TOM"
  }.freeze

  # ISS still emits the legacy "SUR"/"RUR" codes for the rouble alongside the
  # modern "RUB"; normalize so Price/Rate currencies are ISO 4217.
  CURRENCY_ALIASES = { "SUR" => "RUB", "RUR" => "RUB" }.freeze

  # Search/MOEX-suffix aliases users paste (Yahoo's ".ME", common ".MOEX"/MIC
  # forms). ISIN queries are handled natively by ISS `q=`.
  ALIAS_SUFFIX = /\.(ME|MOEX|MISX|MCX)\z/i

  # ISS history blocks page at 100 rows; keep a defensive cap so a misbehaving
  # endpoint can't loop forever.
  HISTORY_PAGE_SIZE = 100
  MAX_HISTORY_PAGES = 500

  SEARCH_CACHE_TTL = 5.minutes
  INSTRUMENT_CACHE_TTL = 24.hours

  # When a single FX date falls on a weekend/holiday, look back this many days so
  # we can return the most recent prior trading-day quote instead of failing.
  FX_RATE_LOOKBACK_DAYS = 10

  def initialize
    # No API key required — public market data only.
  end

  def healthy?
    with_provider_response do
      get_json("/index.json", "iss.meta" => "off")
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
      query = normalize_query(symbol)
      next [] if query.empty?

      rows = search_rows(query)

      securities = rows.filter_map do |row|
        next nil unless row_traded?(row)
        next nil if security_kind(row["group"], row["type"]).nil?

        Provider::SecurityConcept::Security.new(
          symbol: row["secid"].to_s,
          name: (row["shortname"].presence || row["secid"]).to_s,
          logo_url: nil,
          exchange_operating_mic: MOEX_MIC,
          country_code: nil,
          currency: normalize_currency(row["currencyid"].presence || row["faceunit"])
        )
      end

      securities.uniq(&:symbol)
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      instrument = resolve_instrument(normalize_secid(symbol))

      SecurityInfo.new(
        symbol: instrument[:secid],
        name: instrument[:name],
        # Deliberately no website: moex.com is the exchange, not the issuer, so
        # persisting it as website_url makes Brandfetch render the exchange logo
        # for every instrument and shadows the real per-issuer brand logo.
        links: nil,
        logo_url: nil,
        description: nil,
        kind: instrument[:kind],
        exchange_operating_mic: MOEX_MIC
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

      # Exact date if present, else the nearest available close on or before it.
      historical.data.find { |p| p.date == date } ||
        historical.data.select { |p| p.date <= date }.max_by(&:date) ||
        historical.data.first
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic:, start_date:, end_date:)
    with_provider_response do
      secid = normalize_secid(symbol)
      instrument = resolve_instrument(secid)
      bond = instrument[:market].to_s.downcase == "bonds"

      prices = history_prices(secid, instrument, start_date, end_date, bond)

      # The history endpoint does not carry the live/most-recent session, so for
      # a range reaching today append the current marketdata price.
      if end_date >= Date.current
        current = current_price(secid, instrument, bond)
        if current
          prices.reject! { |p| p.date == current.date }
          prices << current
        end
      end

      # Illiquid / non-trading window with nothing returned — fall back to the
      # most recent available close so the caller still gets a value.
      if prices.empty?
        fallback = latest_history_price(secid, instrument, bond, end_date)
        prices << fallback if fallback
      end

      prices.sort_by(&:date)
    end
  end

  def max_history_days
    nil # ISS serves full history.
  end

  # ================================
  #          Exchange Rates
  # ================================

  def fetch_exchange_rate(from:, to:, date:)
    with_provider_response do
      # Fetch a short lookback window, not just the exact day, so a weekend or
      # holiday request still resolves to the previous trading day's close.
      rates = exchange_rates(from, to, date - FX_RATE_LOOKBACK_DAYS, date)
      raise Error, "No MOEX FX rate for #{from}/#{to} on #{date}" if rates.blank?

      rates.find { |r| r.date == date } ||
        rates.select { |r| r.date <= date }.max_by(&:date) ||
        rates.first
    end
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    with_provider_response do
      exchange_rates(from, to, start_date, end_date)
    end
  end

  private

    # ================================
    #          HTTP / parsing
    # ================================

    def base_url
      ENV["MOEX_ISS_URL"].presence || "https://iss.moex.com/iss"
    end

    def get_json(path, params = {})
      throttle_request
      response = client.get("#{base_url}#{path}") do |req|
        params.each { |k, v| req.params[k] = v }
      end
      JSON.parse(response.body)
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        # Generous enough for a full history page but bounded so a hung ISS
        # endpoint can't stall a worker indefinitely.
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

    # Turns a column-array ISS block into an array of hashes keyed by lowercased
    # column name, so callers reference columns by name regardless of ISS order
    # or casing (search columns are lowercase; marketdata columns are uppercase).
    def rows_from(body, block)
      section = body[block] || {}
      columns = section["columns"] || []
      data = section["data"] || []
      index = {}
      columns.each_with_index { |col, i| index[col.to_s.downcase] = i }
      data.map do |row|
        hash = {}
        index.each { |col, i| hash[col] = row[i] }
        hash
      end
    end

    # The /securities/<SECID>.json `description` block is a vertical key/value
    # table (one property per row). Returns { "TYPE" => "common_share", ... }.
    def description_map(body)
      rows_from(body, "description").each_with_object({}) do |row, map|
        map[row["name"].to_s.upcase] = row["value"]
      end
    end

    # ================================
    #            Search
    # ================================

    def search_rows(query)
      Rails.cache.fetch("moex_public:search:#{query}", expires_in: SEARCH_CACHE_TTL) do
        body = get_json("/securities.json", "q" => query, "iss.meta" => "off")
        rows_from(body, "securities")
      end
    end

    def normalize_query(symbol)
      symbol.to_s.strip.upcase.sub(ALIAS_SUFFIX, "")
    end

    def normalize_secid(symbol)
      normalize_query(symbol)
    end

    def row_traded?(row)
      (row["is_traded"] || row["is_trading"]).to_s == "1"
    end

    # Classifies an instrument into "stock"/"fund"/"bond" from its ISS
    # group/type, returning nil for everything we don't surface (indices,
    # futures, currencies). Used both to filter search and to label info.
    def security_kind(group, type)
      g = group.to_s.downcase
      t = type.to_s.downcase

      return "bond" if g.include?("bond") || t.include?("bond")
      return "fund" if g.include?("etf") || g.include?("ppif") || g.include?("fund") || t.include?("etf") || t.include?("ppif")
      return "stock" if g.include?("shares") || t.include?("share") || t.include?("_dr") || t.include?("depositary")

      nil
    end

    def market_kind(market)
      case market.to_s.downcase
      when "bonds" then "bond"
      when /index/ then "index"
      else "stock"
      end
    end

    # ================================
    #     Board / engine resolution
    # ================================

    # Resolves a SECID to its primary trading board plus engine/market, currency,
    # display name, and kind. Cached 24h — reference data that rarely changes.
    def resolve_instrument(secid)
      cached = Rails.cache.fetch("moex_public:instrument:#{secid}", expires_in: INSTRUMENT_CACHE_TTL) do
        body = get_json("/securities/#{secid}.json", "iss.meta" => "off")
        desc = description_map(body)
        boards = rows_from(body, "boards")
        raise InvalidSecurityPriceError, "Unknown MOEX security: #{secid}" if boards.empty?

        board = choose_board(boards)
        kind = security_kind(desc["GROUP"] || desc["TYPE"], desc["TYPE"]) || market_kind(board["market"])

        {
          secid: secid,
          engine: board["engine"].to_s,
          market: board["market"].to_s,
          board: board["boardid"].to_s,
          currency: normalize_currency(board["currencyid"].presence || desc["FACEUNIT"].presence || desc["CURRENCYID"]),
          name: (desc["SHORTNAME"].presence || desc["NAME"].presence || secid).to_s,
          kind: kind
        }
      end

      cached.symbolize_keys
    end

    def choose_board(boards)
      traded = boards.select { |b| b["is_traded"].to_s == "1" }
      pool = traded.any? ? traded : boards

      pool.find { |b| b["is_primary"].to_s == "1" } ||
        by_priority(pool) ||
        pool.first
    end

    def by_priority(boards)
      BOARD_PRIORITY.each do |boardid|
        found = boards.find { |b| b["boardid"].to_s == boardid }
        return found if found
      end
      nil
    end

    def market_securities_path(instrument, secid)
      "/engines/#{instrument[:engine]}/markets/#{instrument[:market]}/boards/#{instrument[:board]}/securities/#{secid}.json"
    end

    def history_path(instrument, secid)
      "/history/engines/#{instrument[:engine]}/markets/#{instrument[:market]}/boards/#{instrument[:board]}/securities/#{secid}.json"
    end

    # ================================
    #         Security prices
    # ================================

    # Live (or most-recent-session) price via the marketdata fallback chain.
    # Bonds quote in % of par, so multiply by the instrument FACEVALUE.
    def current_price(secid, instrument, bond)
      body = get_json(
        market_securities_path(instrument, secid),
        "iss.meta" => "off", "iss.only" => "securities,marketdata"
      )

      sec = rows_from(body, "securities").first || {}
      md  = rows_from(body, "marketdata").first || {}

      raw = md["last"].presence || md["marketprice"].presence || md["lcurrentprice"].presence ||
            md["lcloseprice"].presence || sec["prevprice"].presence
      return nil if raw.nil?

      value = raw.to_f
      return nil if value <= 0

      value = bond_price(value, sec["facevalue"]) if bond
      currency = normalize_currency(sec["currencyid"].presence || sec["faceunit"].presence || instrument[:currency])

      Price.new(
        symbol: secid,
        date: Date.current,
        price: value,
        currency: currency,
        exchange_operating_mic: MOEX_MIC
      )
    end

    def history_prices(secid, instrument, start_date, end_date, bond)
      return [] if start_date > end_date

      prices = []
      start = 0
      pages = 0

      loop do
        body = get_json(
          history_path(instrument, secid),
          "iss.meta" => "off", "from" => start_date.to_s, "till" => end_date.to_s, "start" => start
        )
        rows = rows_from(body, "history")
        break if rows.empty?

        rows.each do |row|
          price = history_row_price(secid, row, instrument, bond)
          prices << price if price
        end

        pages += 1
        break if rows.size < HISTORY_PAGE_SIZE || pages >= MAX_HISTORY_PAGES
        start += rows.size
      end

      prices
    end

    # Fetches just the most recent close within a short lookback window — the
    # fallback when neither history (for the requested range) nor live
    # marketdata yielded anything.
    def latest_history_price(secid, instrument, bond, end_date)
      lookback_start = end_date - 14
      history_prices(secid, instrument, lookback_start, end_date, bond).max_by(&:date)
    end

    def history_row_price(secid, row, instrument, bond)
      date = parse_iss_date(row["tradedate"], context: secid)
      return nil if date.nil?

      raw = row["close"].presence || row["legalcloseprice"].presence
      return nil if raw.nil?

      value = raw.to_f
      return nil if value <= 0

      value = bond_price(value, row["facevalue"]) if bond
      currency = normalize_currency(
        (bond ? row["faceunit"].presence : nil) || row["currencyid"].presence || instrument[:currency]
      )

      Price.new(
        symbol: secid,
        date: date,
        price: value,
        currency: currency,
        exchange_operating_mic: MOEX_MIC
      )
    end

    # Clean price for bonds: percent-of-par × FACEVALUE / 100. NKD/accrued
    # coupon is deliberately excluded (dirty price is out of scope). FACEVALUE
    # is read per row so amortizing bonds price correctly across their life.
    def bond_price(percent, facevalue)
      face = facevalue.to_f
      return percent if face <= 0 # no face value — leave the raw quote untouched
      (percent / 100.0) * face
    end

    # ================================
    #          Exchange rates
    # ================================

    # Returns Rate[] for a RUB-crossed pair, or [] for anything else (other
    # providers handle non-RUB pairs). selt is quoted X/RUB; we invert for RUB→X.
    def exchange_rates(from, to, start_date, end_date)
      pair = fx_pair(from, to)
      return [] unless pair

      instrument = FX_INSTRUMENTS.fetch(pair[:currency])
      quotes = fx_history(instrument, start_date, end_date)

      if end_date >= Date.current
        current = fx_current(instrument)
        if current
          quotes.reject! { |q| q[:date] == current[:date] }
          quotes << current
        end
      end

      quotes.map do |quote|
        rate = if pair[:invert]
          (BigDecimal("1") / BigDecimal(quote[:value].to_s)).round(12)
        else
          quote[:value]
        end
        Rate.new(date: quote[:date], from: from, to: to, rate: rate)
      end.sort_by(&:date)
    end

    # { currency: "USD", invert: false } for X→RUB; invert: true for RUB→X; nil
    # when neither side is RUB or the foreign side is unsupported.
    def fx_pair(from, to)
      f = from.to_s.upcase
      t = to.to_s.upcase

      if f == "RUB" && FX_INSTRUMENTS.key?(t)
        { currency: t, invert: true }
      elsif t == "RUB" && FX_INSTRUMENTS.key?(f)
        { currency: f, invert: false }
      end
    end

    def fx_current(instrument)
      body = get_json(
        "/engines/currency/markets/selt/boards/CETS/securities/#{instrument}.json",
        "iss.meta" => "off", "iss.only" => "marketdata"
      )
      md = rows_from(body, "marketdata").first || {}

      raw = md["last"].presence || md["waprice"].presence || md["marketprice"].presence || md["lcloseprice"].presence
      return nil if raw.nil?

      value = raw.to_f
      return nil if value <= 0

      { date: Date.current, value: value }
    end

    def fx_history(instrument, start_date, end_date)
      return [] if start_date > end_date

      quotes = []
      start = 0
      pages = 0

      loop do
        body = get_json(
          "/history/engines/currency/markets/selt/boards/CETS/securities/#{instrument}.json",
          "iss.meta" => "off", "from" => start_date.to_s, "till" => end_date.to_s, "start" => start
        )
        rows = rows_from(body, "history")
        break if rows.empty?

        rows.each do |row|
          date = parse_iss_date(row["tradedate"], context: instrument)
          next if date.nil?

          raw = row["close"].presence || row["waprice"].presence
          next if raw.nil?

          value = raw.to_f
          next if value <= 0

          quotes << { date: date, value: value }
        end

        pages += 1
        break if rows.size < HISTORY_PAGE_SIZE || pages >= MAX_HISTORY_PAGES
        start += rows.size
      end

      quotes
    end

    # ================================
    #            Helpers
    # ================================

    # Parses an ISS TRADEDATE, skipping (rather than raising on) a malformed
    # value so one bad row can't fail an entire history fetch. Logs the offending
    # value with context for actionable diagnostics.
    def parse_iss_date(raw, context:)
      return nil if raw.blank?
      Date.parse(raw.to_s)
    rescue Date::Error
      Rails.logger.warn("MoexPublic: skipping #{context} history row with unparseable date #{raw.inspect}")
      nil
    end

    def normalize_currency(code)
      return "RUB" if code.blank?
      upcased = code.to_s.upcase
      CURRENCY_ALIASES.fetch(upcased, upcased)
    end

    # Preserve MoexPublic::Error subclasses (e.g. InvalidSecurityPriceError)
    # through with_provider_response, mirroring BinancePublic. The inherited
    # RateLimitable transformer would otherwise downcast them to Error.
    def default_error_transformer(error)
      return error if error.is_a?(self.class::Error)
      super
    end
end
