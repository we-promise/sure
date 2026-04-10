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
  def get_spot_trades(symbol, limit: 1000, from_id: nil)
    params = { "symbol" => symbol, "limit" => limit.to_s }
    params["fromId"] = from_id.to_s if from_id
    signed_get("/api/v3/myTrades", extra_params: params)
  end

  private

    def signed_get(path, extra_params: {})
      params = timestamp_params.merge(extra_params)
      query_string = URI.encode_www_form(params.sort)

      response = self.class.get(
        path,
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
