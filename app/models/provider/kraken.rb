# frozen_string_literal: true

require "bigdecimal"
require "json"

class Provider::Kraken
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class PermissionError < Error; end
  class RateLimitError < Error; end
  class NonceError < Error; end
  class OTPRequiredError < Error; end
  class ApiError < Error; end

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

  # Each native reader returns one original envelope. Ingestion owns durable
  # pagination and retries; a fresh signed request always allocates a nonce.
  def get_api_key_info_snapshot
    private_snapshot("GetApiKeyInfo")
  end

  def get_extended_balance_snapshot
    private_snapshot("BalanceEx")
  end

  def get_asset_info_snapshot
    public_snapshot("Assets")
  end

  def get_asset_pairs_snapshot
    public_snapshot("AssetPairs")
  end

  # The public all-market response avoids an HTTP request per owned asset.
  def get_ticker_snapshot
    public_snapshot("Ticker")
  end

  # https://docs.kraken.com/api-reference/account-data/get-trades-history
  def get_trades_history_page(start: nil, end_at:, offset: 0)
    private_snapshot("TradesHistory", native_history_params(start, end_at, offset).merge("limit" => "50", "consolidate_taker" => "true"))
  end

  # https://docs.kraken.com/api-reference/account-data/get-ledgers-info
  def get_ledgers_page(start: nil, end_at:, offset: 0)
    private_snapshot("Ledgers", native_history_params(start, end_at, offset))
  end

  private

    attr_reader :nonce_generator

    def native_history_params(start, finish, offset)
      unless (start.nil? || (start.is_a?(Integer) && start >= 0)) && finish.is_a?(Integer) && finish.positive? &&
          (start.nil? || start < finish) && offset.is_a?(Integer) && offset >= 0
        raise ArgumentError, "Invalid Kraken history request scope"
      end
      { "start" => start&.to_s, "end" => finish.to_s, "ofs" => offset.to_s, "without_count" => "false" }.compact
    end

    def public_snapshot(method)
      snapshot_response(self.class.get("#{PUBLIC_PREFIX}/#{method}", query: {}))
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, SystemCallError, EOFError
      raise ApiError, "Kraken network request failed", cause: nil
    end

    def private_snapshot(method, params = {})
      unless api_key.is_a?(String) && api_key.present? && api_secret.is_a?(String) && api_secret.present?
        raise AuthenticationError, "Kraken credentials are required"
      end
      begin
        raise ArgumentError if Base64.strict_decode64(api_secret).empty?
      rescue ArgumentError
        raise AuthenticationError, "Invalid Kraken credential encoding", cause: nil
      end
      nonce = nonce_generator.call.to_s
      unless nonce.match?(/\A[0-9]+\z/) && nonce.to_i.positive? && nonce.to_i <= 9_223_372_036_854_775_807
        raise NonceError, "Invalid Kraken nonce allocation"
      end
      path = "#{PRIVATE_PREFIX}/#{method}"
      request_params = { "nonce" => nonce }.merge(params)
      snapshot_response(self.class.post(path, body: URI.encode_www_form(request_params),
        headers: auth_headers(path, request_params).merge("Content-Type" => "application/x-www-form-urlencoded")))
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, SystemCallError, EOFError
      raise ApiError, "Kraken network request failed", cause: nil
    end

    def snapshot_response(response)
      raise ApiError, "Kraken HTTP request failed" unless response.code.between?(200, 299)
      parsed = JSON.parse(response.body, decimal_class: BigDecimal)
      unless parsed.is_a?(Hash) && parsed["error"].is_a?(Array) && parsed["error"].all? { |value| value.is_a?(String) }
        raise ApiError, "Invalid Kraken response envelope"
      end
      errors = parsed["error"].reject(&:blank?)
      if errors.any?
        classified = classified_error(errors)
        raise classified.class, "Kraken account data request failed", cause: nil
      end
      raise ApiError, "Invalid Kraken result" unless parsed["result"].is_a?(Hash)
      parsed
    rescue JSON::ParserError, TypeError
      raise ApiError, "Invalid Kraken JSON response", cause: nil
    end

    def public_get(method, params = {})
      response = self.class.get("#{PUBLIC_PREFIX}/#{method}", query: params)
      handle_response(response)
    end

    def private_post(method, params = {})
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
