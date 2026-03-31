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
    utc_day_start = Time.utc(date.year, date.month, date.day)
    day_start = utc_day_start.to_i * 1000
    day_end = utc_day_start.end_of_day.to_i * 1000

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
      parsed = JSON.parse(response.body) if parsed.is_a?(String)
      message = extract_error_message(parsed)

      case response.code.to_i
      when 200..299
        parsed
      else
        if authentication_error?(response.code, message)
          raise AuthenticationError, message.presence || "Unauthorized - check your Binance API key permissions"
        elsif rate_limit_error?(response.code, message)
          raise RateLimitError, message.presence || "Binance rate limit exceeded"
        else
          raise ApiError, message.presence || "Binance API error: #{response.code}"
        end
      end
    rescue JSON::ParserError => e
      raise ApiError, "Binance API returned invalid JSON: #{e.message}"
    end

    def extract_error_message(parsed)
      return parsed if parsed.is_a?(String)
      return nil unless parsed.is_a?(Hash)

      parsed["msg"] || parsed["message"] || parsed["error"]
    end

    def authentication_error?(status_code, message)
      return true if status_code.to_i.in?([ 401, 403 ])
      return false if message.blank?

      message.match?(
        /invalid api[- ]?key|invalid signature|signature for this request|timestamp for this request|recvwindow|permissions for action/i
      )
    end

    def rate_limit_error?(status_code, message)
      return true if status_code.to_i.in?([ 418, 429 ])
      return false if message.blank?

      message.match?(/rate limit|too many requests|too much request weight/i)
    end
end
