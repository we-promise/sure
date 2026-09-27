# frozen_string_literal: true

class Provider::Kraken
  include HTTParty
  include Provider::RateLimitable  # fully qualified: Provider::Kraken does not inherit from Provider, unlike the other includers
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class PermissionError < Error; end
  class RateLimitError < Error; end
  class NonceError < Error; end
  class OTPRequiredError < Error; end
  class ApiError < Error; end

  # Kraken meters private endpoints with a counter that decays by 0.5 points
  # per second (1.0 on higher-limit accounts) against a cap of 20. Ordinary
  # calls cost 1 point; public endpoints are limited separately, per IP, at
  # about one per second. One interval covers both.
  MIN_REQUEST_INTERVAL = 1.0

  # Account-history endpoints cost 4 points each. The paginated backfills
  # (MAX_LEDGER_PAGES = 200) issue them back to back, so they get their own,
  # slower pacing: 4 points at the slowest decay is one call every 8 seconds,
  # which a sustained run cannot exceed once the initial allowance is spent.
  # Overridable through KRAKEN_HISTORY_MIN_REQUEST_INTERVAL; higher-limit
  # accounts can halve it.
  HISTORY_MIN_REQUEST_INTERVAL = 8.0
  HISTORY_METHODS = %w[Ledgers QueryLedgers TradesHistory QueryTrades ClosedOrders].freeze

  BASE_URL = "https://api.kraken.com"
  PRIVATE_PREFIX = "/0/private"
  PUBLIC_PREFIX = "/0/public"

  base_uri BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :api_secret

  def initialize(api_key:, api_secret:, nonce_generator: nil)
    @api_key = api_key # pipelock:ignore user-supplied Kraken credential kept in memory for signed requests
    @api_secret = api_secret # pipelock:ignore user-supplied Kraken credential kept in memory for signed requests
    @nonce_generator = nonce_generator || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond).to_s }
  end

  def get_api_key_info
    private_post("GetApiKeyInfo")
  end

  def get_extended_balance
    private_post("BalanceEx")
  end

  def get_trades_history(start: nil, offset: nil)
    params = {}
    params["start"] = start.to_i.to_s if start.present?
    params["ofs"] = offset.to_i.to_s if offset.present?

    private_post("TradesHistory", params)
  end

  def get_ledgers(start: nil, type: nil, offset: nil)
    params = {}
    params["start"] = start.to_i.to_s if start.present?
    params["type"] = type.to_s if type.present?
    params["ofs"] = offset.to_i.to_s if offset.present?

    private_post("Ledgers", params)
  end

  def get_asset_info(asset: nil)
    params = {}
    params["asset"] = asset if asset.present?
    public_get("Assets", params)
  end

  def get_asset_pairs(pair: nil)
    params = {}
    params["pair"] = pair if pair.present?
    public_get("AssetPairs", params)
  end

  def get_ticker(pair)
    public_get("Ticker", "pair" => pair)
  end

  def get_ohlc(pair, interval: 1440, since: nil)
    params = { "pair" => pair, "interval" => interval.to_s }
    params["since"] = since.to_i.to_s if since.present?
    public_get("OHLC", params)
  end

  private

    attr_reader :nonce_generator

    def public_get(method, params = {})
      throttle_request
      response = self.class.get("#{PUBLIC_PREFIX}/#{method}", query: params)
      handle_response(response)
    end

    def private_post(method, params = {})
      HISTORY_METHODS.include?(method) ? throttle_history_request : throttle_request
      path = "#{PRIVATE_PREFIX}/#{method}"
      request_params = { "nonce" => nonce_generator.call.to_s }.merge(stringify_params(params))
      body = URI.encode_www_form(request_params)

      response = self.class.post(
        path,
        body: body,
        headers: auth_headers(path, request_params).merge("Content-Type" => "application/x-www-form-urlencoded")
      )

      handle_response(response)
    end

    def stringify_params(params)
      params.each_with_object({}) { |(key, value), hash| hash[key.to_s] = value.to_s }
    end

    def auth_headers(path, params)
      {
        "API-Key" => api_key,
        "API-Sign" => sign(path, params)
      }
    end

    def sign(path, params)
      encoded_payload = URI.encode_www_form(params)
      nonce = params.fetch("nonce").to_s
      digest = OpenSSL::Digest::SHA256.digest(nonce + encoded_payload)
      hmac = OpenSSL::HMAC.digest("sha512", Base64.decode64(api_secret), path + digest)
      Base64.strict_encode64(hmac)
    end

    # Same shape as RateLimitable#throttle_request, on its own clock: a history
    # call is spaced from the previous history call, whatever else went out in
    # between.
    def throttle_history_request
      @last_history_request_time ||= Time.at(0)
      sleep_time = history_min_request_interval - (Time.current - @last_history_request_time)
      sleep(sleep_time) if sleep_time > 0
      @last_history_request_time = Time.current
    end

    def history_min_request_interval
      positive_interval(ENV.fetch("KRAKEN_HISTORY_MIN_REQUEST_INTERVAL", HISTORY_MIN_REQUEST_INTERVAL), "KRAKEN_HISTORY_MIN_REQUEST_INTERVAL")
    end

    def handle_response(response)
      parsed = response.parsed_response

      unless response.code.between?(200, 299)
        raise ApiError, "Kraken API request failed: #{response.code}"
      end

      unless parsed.is_a?(Hash)
        raise ApiError, "Malformed Kraken API response"
      end

      unless parsed.key?("error")
        raise ApiError, "Malformed Kraken API response: missing error"
      end

      errors = Array(parsed["error"]).reject(&:blank?)
      raise classified_error(errors) if errors.any?

      unless parsed.key?("result")
        raise ApiError, "Malformed Kraken API response: missing result"
      end

      parsed["result"]
    end

    def classified_error(errors)
      message = errors.join(", ")

      case message
      when /Invalid key|Invalid signature|Temporary lockout/i
        AuthenticationError.new(message)
      when /Invalid nonce/i
        NonceError.new(message)
      when /Permission denied|Invalid permissions/i
        PermissionError.new(message)
      when /Rate limit exceeded|Too many requests|limit exceeded|Throttled/i
        RateLimitError.new(message)
      when /otp|2fa|two.factor/i
        OTPRequiredError.new(message)
      else
        ApiError.new(message)
      end
    end
end
