# frozen_string_literal: true

class Provider::Bitstamp
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class PermissionError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  BASE_URL = "https://www.bitstamp.net"
  API_PREFIX = "/api/v2"

  base_uri BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :api_secret

  def initialize(api_key:, api_secret:)
    @api_key = api_key # pipelock:ignore user-supplied Bitstamp credential kept in memory for signed requests
    @api_secret = api_secret # pipelock:ignore user-supplied Bitstamp credential kept in memory for signed requests
  end

  def get_account_balances
    authenticated_post("account_balances/")
  end

  def get_user_transactions(offset: 0, limit: 1000, since_timestamp: nil)
    params = { "offset" => offset.to_s, "limit" => limit.to_s, "sort" => "desc" }
    params["since_timestamp"] = since_timestamp.to_i.to_s if since_timestamp.present?
    authenticated_post("user_transactions/", params)
  end

  def get_ticker(currency_pair)
    public_get("ticker/#{currency_pair}/")
  end

  def get_trading_pairs
    public_get("trading-pairs-info/")
  end

  def get_earn_subscriptions
    authenticated_get("earn/subscriptions/")
  end

  def get_earn_transactions(offset: 0, limit: 1000)
    params = { "offset" => offset.to_s, "limit" => limit.to_s }
    authenticated_get("earn/transactions/", params)
  end

  private

    def public_get(endpoint, params = {})
      response = self.class.get("#{API_PREFIX}/#{endpoint}", query: params.presence)
      handle_response(response)
    end

    def authenticated_get(endpoint, params = {})
      path = "#{API_PREFIX}/#{endpoint}"
      query_string = params.presence ? URI.encode_www_form(params) : ""
      nonce = SecureRandom.uuid
      timestamp = (Time.now.to_f * 1000).to_i.to_s

      signature = sign("GET", path, nonce, timestamp, "", "", query_string: query_string)

      headers = {
        "X-Auth" => "BITSTAMP #{api_key}",
        "X-Auth-Signature" => signature,
        "X-Auth-Timestamp" => timestamp,
        "X-Auth-Nonce" => nonce,
        "X-Auth-Version" => "v2"
      }

      response = self.class.get(path, headers: headers, query: params.presence)
      handle_response(response)
    end

    def authenticated_post(endpoint, body_params = {})
      path = "#{API_PREFIX}/#{endpoint}"
      nonce = SecureRandom.uuid
      timestamp = (Time.now.to_f * 1000).to_i.to_s
      payload = body_params.any? ? URI.encode_www_form(body_params) : ""
      content_type = payload.present? ? "application/x-www-form-urlencoded" : ""

      signature = sign("POST", path, nonce, timestamp, content_type, payload, query_string: "")

      headers = {
        "X-Auth" => "BITSTAMP #{api_key}",
        "X-Auth-Signature" => signature,
        "X-Auth-Timestamp" => timestamp,
        "X-Auth-Nonce" => nonce,
        "X-Auth-Version" => "v2"
      }
      headers["Content-Type"] = content_type if content_type.present?

      response = self.class.post(
        path,
        headers: headers,
        body: payload.presence
      )

      handle_response(response)
    end

    def sign(http_verb, path, nonce, timestamp, content_type, payload, query_string: "")
      message = [
        "BITSTAMP #{api_key}",
        http_verb,
        "www.bitstamp.net",
        path,
        query_string,
        content_type,
        nonce,
        timestamp,
        "v2",
        payload
      ].join

      OpenSSL::HMAC.hexdigest("sha256", api_secret, message).upcase
    end

    def handle_response(response)
      unless response.code.between?(200, 299)
        raise classified_http_error(response.code, response.body)
      end

      parsed = response.parsed_response

      unless parsed.is_a?(Array) || parsed.is_a?(Hash)
        raise ApiError, "Malformed Bitstamp API response"
      end

      if parsed.is_a?(Hash) && parsed["status"] == "error"
        raise classified_api_error(parsed["reason"].to_s)
      end

      parsed
    end

    def classified_http_error(code, body)
      message = "Bitstamp API error #{code}: #{body.to_s.first(200)}"
      case code
      when 401, 403
        AuthenticationError.new(message)
      when 429
        RateLimitError.new(message)
      else
        ApiError.new(message)
      end
    end

    def classified_api_error(reason)
      case reason
      when /Invalid API key|Invalid signature|Invalid nonce/i
        AuthenticationError.new(reason)
      when /Permission denied|Unauthorized/i
        PermissionError.new(reason)
      when /Rate limit/i
        RateLimitError.new(reason)
      else
        ApiError.new(reason)
      end
    end
end
