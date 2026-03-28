class Provider::Binance
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  API_BASE_URL = "https://api.binance.com".freeze

  base_uri API_BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :api_secret

  def initialize(api_key:, api_secret:)
    @api_key = api_key
    @api_secret = api_secret
  end

  def get_account(omit_zero_balances: true)
    signed_get("/api/v3/account", omitZeroBalances: omit_zero_balances)
  end

  def get_all_coin_info
    signed_get("/sapi/v1/capital/config/getall")
  end

  def get_exchange_info
    public_get("/api/v3/exchangeInfo")
  end

  def get_all_prices
    Array(public_get("/api/v3/ticker/price")).each_with_object({}) do |price_data, prices|
      prices[price_data["symbol"]] = BigDecimal(price_data["price"].to_s)
    end
  end

  def get_deposit_history(start_time:, end_time:, offset: 0, limit: 1000)
    signed_get(
      "/sapi/v1/capital/deposit/hisrec",
      startTime: start_time,
      endTime: end_time,
      offset: offset,
      limit: limit
    )
  end

  def get_withdraw_history(start_time:, end_time:, offset: 0, limit: 1000)
    signed_get(
      "/sapi/v1/capital/withdraw/history",
      startTime: start_time,
      endTime: end_time,
      offset: offset,
      limit: limit
    )
  end

  def get_my_trades(symbol:, start_time: nil, end_time: nil, from_id: nil, limit: 1000)
    signed_get(
      "/api/v3/myTrades",
      symbol: symbol,
      startTime: start_time,
      endTime: end_time,
      fromId: from_id,
      limit: limit
    )
  end

  def get_daily_klines(symbol:, date:)
    day_start = date.to_time.utc.beginning_of_day.to_i * 1000
    day_end = date.to_time.utc.end_of_day.to_i * 1000

    public_get(
      "/api/v3/klines",
      symbol: symbol,
      interval: "1d",
      startTime: day_start,
      endTime: day_end,
      limit: 1
    )
  end

  private

    def public_get(path, params = {})
      response = self.class.get(build_url(path, params))
      handle_response(response)
    end

    def signed_get(path, params = {})
      signed_params = params.compact.merge(timestamp: current_timestamp_ms)
      payload = query_string(signed_params)
      signature = OpenSSL::HMAC.hexdigest("SHA256", api_secret, payload)
      response = self.class.get(
        "#{path}?#{payload}&signature=#{signature}",
        headers: auth_headers
      )
      handle_response(response)
    end

    def build_url(path, params)
      query = query_string(params.compact)
      query.present? ? "#{path}?#{query}" : path
    end

    def query_string(params)
      URI.encode_www_form(params.transform_keys(&:to_s))
    end

    def auth_headers
      {
        "X-MBX-APIKEY" => api_key,
        "Content-Type" => "application/json"
      }
    end

    def current_timestamp_ms
      @server_time_offset_ms ||= compute_server_time_offset_ms
      (Time.now.to_f * 1000).to_i + @server_time_offset_ms
    end

    def compute_server_time_offset_ms
      local_before = (Time.now.to_f * 1000).to_i
      response = public_get("/api/v3/time")
      local_after = (Time.now.to_f * 1000).to_i
      midpoint = (local_before + local_after) / 2
      response["serverTime"].to_i - midpoint
    rescue StandardError
      0
    end

    def handle_response(response)
      parsed = response.parsed_response

      case response.code
      when 200..299
        parsed
      when 401, 403
        raise AuthenticationError, extract_error_message(parsed) || "Unauthorized - check your Binance API key permissions"
      when 418, 429
        raise RateLimitError, extract_error_message(parsed) || "Binance rate limit exceeded"
      else
        raise ApiError, extract_error_message(parsed) || "Binance API error: #{response.code}"
      end
    end

    def extract_error_message(parsed)
      return parsed if parsed.is_a?(String)
      return nil unless parsed.is_a?(Hash)

      parsed["msg"] || parsed["message"] || parsed["error"]
    end
end
