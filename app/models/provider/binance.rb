class Provider::Binance
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end
  class InvalidSymbolError < ApiError; end

  # Pipelock false positive: This constant and the base_uri below trigger a "Credential in URL"
  # warning because of the presence of @api_key and @api_secret variables in this file.
  # Pipelock incorrectly interprets the '@' in Ruby instance variables as a password delimiter
  # in an URL (e.g. https://user:password@host).
  SPOT_BASE_URL = "https://api.binance.com".freeze
  FUTURES_BASE_URL = "https://fapi.binance.com".freeze

  base_uri SPOT_BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :api_secret

  def initialize(api_key:, api_secret:)
    @api_key = api_key
    @api_secret = api_secret
  end

  # Spot wallet — requires signed request
  def get_spot_account
    signed_get("/api/v3/account")
  end

  # Margin account — requires signed request
  def get_margin_account
    signed_get("/sapi/v1/margin/account")
  end

  # Simple Earn flexible positions — requires signed request
  def get_simple_earn_flexible
    signed_get("/sapi/v1/simple-earn/flexible/position")
  end

  # Simple Earn locked positions — requires signed request
  def get_simple_earn_locked
    signed_get("/sapi/v1/simple-earn/locked/position")
  end

  # Public endpoint — no auth needed
  # symbol e.g. "BTCUSDT"
  # Returns price string or nil on failure
  def get_spot_price(symbol)
    response = self.class.get("/api/v3/ticker/price", query: { symbol: symbol })
    data = handle_response(response)
    data["price"]
  rescue StandardError => e
    Rails.logger.warn("Provider::Binance: failed to fetch price for #{symbol}: #{e.message}")
    nil
  end

  # Public endpoint — fetch historical kline close price for a date
  # symbol e.g. "BTCUSDT", date e.g. Date or Time
  def get_historical_price(symbol, date)
    timestamp = date.to_time.utc.beginning_of_day.to_i * 1000

    response = self.class.get("/api/v3/klines", query: {
      symbol: symbol,
      interval: "1d",
      startTime: timestamp,
      limit: 1
    })

    data = handle_response(response)

    return nil if data.blank? || data.first.blank?

    # Binance klines format: [ Open time, Open, High, Low, Close (index 4), ... ]
    data.first[4]
  rescue StandardError => e
    Rails.logger.warn("Provider::Binance: failed to fetch historical price for #{symbol} on #{date}: #{e.message}")
    nil
  end

  # Signed trade history for a single symbol, e.g. "BTCUSDT".
  # Pass from_id to fetch only trades with id >= from_id (for incremental sync).
  # Pass start_time/end_time (epoch ms) to fetch a bounded window instead; Binance
  # rejects from_id combined with start_time/end_time, so callers use one or the other.
  def get_spot_trades(symbol, limit: 1000, from_id: nil, start_time: nil, end_time: nil)
    params = { "symbol" => symbol, "limit" => limit.to_s }
    params["fromId"] = from_id.to_s if from_id
    params["startTime"] = start_time.to_s if start_time
    params["endTime"] = end_time.to_s if end_time
    signed_get("/api/v3/myTrades", extra_params: params)
  end

  # USDⓈ-M Futures account — requires signed request
  def get_futures_account
    signed_get("/fapi/v2/account", base_url: FUTURES_BASE_URL)
  end

  # Futures trade history for a single symbol
  def get_futures_trades(symbol, limit: 1000, from_id: nil, start_time: nil, end_time: nil)
    params = { "symbol" => symbol, "limit" => limit.to_s }
    params["fromId"] = from_id.to_s if from_id
    params["startTime"] = start_time.to_s if start_time
    params["endTime"] = end_time.to_s if end_time
    signed_get("/fapi/v1/userTrades", extra_params: params, base_url: FUTURES_BASE_URL)
  end

  # P2P trade history — requires signed request
  # Pass start_timestamp to fetch only recent trades (max 30 days window)
  def get_p2p_trades(start_timestamp: nil, end_timestamp: nil)
    params = { "tradeType" => "BUY" } # default to BUY, will loop in processor for SELL
    params["startTimestamp"] = start_timestamp.to_s if start_timestamp
    params["endTimestamp"] = end_timestamp.to_s if end_timestamp
    signed_get("/sapi/v1/c2c/orderMatch/listUserOrderHistory", extra_params: params)
  end

  # Internal helper to handle both buy and sell types since API requires specific tradeType or gets default BUY
  def get_all_p2p_trades(start_timestamp: nil, end_timestamp: nil)
    %w[BUY SELL].flat_map do |trade_type|
      page = 1
      rows = 100
      data = []
      loop do
        result = signed_get(
          "/sapi/v1/c2c/orderMatch/listUserOrderHistory",
          extra_params: {
            "tradeType" => trade_type,
            "startTimestamp" => start_timestamp&.to_s,
            "endTimestamp" => end_timestamp&.to_s,
            "page" => page.to_s,
            "rows" => rows.to_s
          }.compact
        )
        batch = result.is_a?(Hash) ? Array(result["data"]) : []
        data.concat(batch)
        break if batch.size < rows
        page += 1
      end
      data
    end
  end

  # Bounded readers for shared ingestion. Existing importer entry points above
  # retain their response parsing and limits throughout incremental migration.
  def get_portfolio_page(source, page: 1)
    paths = { "spot" => [ "/api/v3/account", "balances" ], "margin" => [ "/sapi/v1/margin/account", "userAssets" ],
      "earn_flexible" => [ "/sapi/v1/simple-earn/flexible/position", "rows" ],
      "earn_locked" => [ "/sapi/v1/simple-earn/locked/position", "rows" ], "futures" => [ "/fapi/v2/account", "assets" ] }
    path, collection = paths.fetch(source) { raise ApiError, "Unknown Binance portfolio source" }
    raise ApiError, "Invalid Binance page" unless page.is_a?(Integer) && page.positive?
    paginated = source.start_with?("earn_")
    raise ApiError, "Binance source has no continuation" if !paginated && page != 1
    data = ingestion_signed_get(path, params: paginated ? { "current" => page.to_s, "size" => "100" } : {},
      base_url: source == "futures" ? FUTURES_BASE_URL : SPOT_BASE_URL)
    raise ApiError, "Invalid Binance portfolio response" unless data.is_a?(Hash)
    rows = ingestion_rows(data[collection], limit: paginated ? 100 : nil)
    total = data["total"]
    if paginated && !total.nil? && !(total.is_a?(Integer) && total >= 0)
      raise ApiError, "Invalid Binance portfolio total"
    end
    if paginated && total && rows.size != [ [ total - (page - 1) * 100, 0 ].max, 100 ].min
      raise ApiError, "Incomplete Binance portfolio page"
    end
    more = paginated && (total ? page * 100 < total : rows.size == 100)
    raise ApiError, "Incomplete Binance portfolio page" if more && rows.empty?
    { items: rows, next_cursor: more ? (page + 1).to_s : nil, evidence: data }
  end

  def get_trades_page(symbol, market:, from_id: nil, start_time: nil, end_time: nil)
    ingestion_symbol(symbol)
    raise ApiError, "Invalid Binance trade market" unless %w[spot futures].include?(market)
    if from_id && (start_time || end_time)
      raise ApiError, "Binance trade IDs cannot be combined with time windows"
    end
    [ from_id, start_time, end_time ].compact.each { |value| raise ApiError, "Invalid Binance trade cursor" unless value.is_a?(Integer) && value >= 0 }
    if start_time || end_time
      span = market == "spot" ? 86_400_000 : 604_800_000
      unless start_time && end_time && end_time >= start_time && end_time - start_time < span
        raise ApiError, "Invalid Binance trade time window"
      end
    end
    params = { "symbol" => symbol, "limit" => "1000", "fromId" => from_id&.to_s,
      "startTime" => start_time&.to_s, "endTime" => end_time&.to_s }.compact
    data = ingestion_signed_get(market == "spot" ? "/api/v3/myTrades" : "/fapi/v1/userTrades", params: params,
      base_url: market == "spot" ? SPOT_BASE_URL : FUTURES_BASE_URL)
    { items: ingestion_rows(data, limit: 1000), next_cursor: nil, evidence: data }
  end

  def get_p2p_page(trade_type:, start_time:, end_time:, page: 1)
    unless %w[BUY SELL].include?(trade_type) && [ start_time, end_time, page ].all? { |value| value.is_a?(Integer) } &&
        start_time >= 0 && end_time >= start_time && end_time - start_time <= 2_592_000_000 && page.positive?
      raise ApiError, "Invalid Binance P2P window"
    end
    data = ingestion_signed_get("/sapi/v1/c2c/orderMatch/listUserOrderHistory", params: {
      "tradeType" => trade_type, "startTimestamp" => start_time.to_s, "endTimestamp" => end_time.to_s,
      "page" => page.to_s, "rows" => "100"
    })
    unless data.is_a?(Hash) && data["success"] != false
      raise ApiError, "Invalid Binance P2P response"
    end
    rows = ingestion_rows(data["data"], limit: 100)
    { items: rows, next_cursor: rows.size == 100 ? (page + 1).to_s : nil, evidence: data }
  end

  def get_price_page(symbol, date: nil)
    ingestion_symbol(symbol)
    query = if date
      raise ApiError, "Invalid Binance price date" unless date.instance_of?(Date)
      { symbol: symbol, interval: "1d", startTime: Time.utc(date.year, date.month, date.day).to_i * 1000, limit: 1 }
    else
      { symbol: symbol }
    end
    data = ingestion_response(self.class.get(date ? "/api/v3/klines" : "/api/v3/ticker/price", query: query))
    price = if date
      unless data.is_a?(Array) && data.size <= 1 && (data.empty? || (data.first.is_a?(Array) && data.first.size >= 5))
        raise ApiError, "Invalid Binance historical price"
      end
      data.first&.[](4)
    else
      raise ApiError, "Invalid Binance price" unless data.is_a?(Hash) && data.key?("price")
      data["price"]
    end
    { items: price.nil? ? [] : [ { "price" => price } ], next_cursor: nil, evidence: data }
  end

  private

    def ingestion_rows(rows, limit:)
      unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) } && (limit.nil? || rows.size <= limit)
        raise ApiError, "Invalid Binance collection"
      end
      rows
    end

    def ingestion_symbol(symbol)
      raise ApiError, "Invalid Binance symbol" unless symbol.is_a?(String) && symbol.match?(/\A[A-Z0-9]+\z/)
    end

    def ingestion_signed_get(path, params: {}, base_url: SPOT_BASE_URL)
      query = URI.encode_www_form(timestamp_params.merge(params).sort)
      ingestion_response(self.class.get(path, base_uri: base_url, query: "#{query}&signature=#{sign(query)}", headers: auth_headers))
    end

    def ingestion_response(response)
      case response.code
      when 401, 403 then raise AuthenticationError, "Binance authorization does not permit this resource"
      when 418, 429 then raise RateLimitError, "Binance request was rate limited"
      end
      data = JSON.parse(response.body, decimal_class: BigDecimal)
      case response.code
      when 200..299 then data
      else
        raise InvalidSymbolError, "Binance symbol is unavailable" if data.is_a?(Hash) && data["code"] == -1121
        raise ApiError, "Binance request failed (HTTP #{response.code})"
      end
    rescue JSON::ParserError, TypeError
      raise ApiError, "Invalid Binance response", cause: nil
    end

    def signed_get(path, extra_params: {}, base_url: SPOT_BASE_URL)
      params = timestamp_params.merge(extra_params)
      query_string = URI.encode_www_form(params.sort)

      response = self.class.get(
        path,
        base_uri: base_url,
        query: "#{query_string}&signature=#{sign(query_string)}",
        headers: auth_headers
      )

      handle_response(response)
    end

    def timestamp_params
      { "timestamp" => (Time.current.to_f * 1000).to_i.to_s, "recvWindow" => "5000" }
    end

    # HMAC-SHA256 of the query string.
    # Accepts either a Hash of params or a pre-built query string.
    def sign(params)
      query_string = params.is_a?(Hash) ? URI.encode_www_form(params.sort) : params
      OpenSSL::HMAC.hexdigest("sha256", api_secret, query_string)
    end

    def auth_headers
      { "X-MBX-APIKEY" => api_key }
    end

    def handle_response(response)
      parsed = response.parsed_response

      case response.code
      when 200..299
        parsed
      when 401
        raise AuthenticationError, extract_error_message(parsed) || "Unauthorized"
      when 429
        raise RateLimitError, "Rate limit exceeded"
      else
        msg = extract_error_message(parsed) || "API error: #{response.code}"
        raise InvalidSymbolError, msg if parsed.is_a?(Hash) && parsed["code"] == -1121
        raise ApiError, msg
      end
    end

    def extract_error_message(parsed)
      return parsed if parsed.is_a?(String)
      return nil unless parsed.is_a?(Hash)
      parsed["msg"] || parsed["message"] || parsed["error"]
    end
end
