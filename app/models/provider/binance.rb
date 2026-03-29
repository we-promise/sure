class Provider::Binance
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

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
  rescue => e
    Rails.logger.warn("Provider::Binance: failed to fetch price for #{symbol}: #{e.message}")
    nil
  end

  # Signed trade history for a single symbol, e.g. "BTCUSDT"
  def get_spot_trades(symbol, limit: 500)
    signed_get("/api/v3/myTrades", extra_params: { "symbol" => symbol, "limit" => limit.to_s })
  end

  private

    def signed_get(path, extra_params: {})
      params = timestamp_params.merge(extra_params)
      params["signature"] = sign(params)

      response = self.class.get(
        path,
        query: params,
        headers: auth_headers
      )

      handle_response(response)
    end

    def timestamp_params
      { "timestamp" => (Time.now.to_f * 1000).to_i.to_s, "recvWindow" => "10000" }
    end

    # HMAC-SHA256 of the sorted query string
    def sign(params)
      query_string = params.sort_by { |k, _| k.to_s }.map { |k, v| "#{k}=#{v}" }.join("&")
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
        raise ApiError, extract_error_message(parsed) || "API error: #{response.code}"
      end
    end

    def extract_error_message(parsed)
      return parsed if parsed.is_a?(String)
      return nil unless parsed.is_a?(Hash)
      parsed["msg"] || parsed["message"] || parsed["error"]
    end
end
